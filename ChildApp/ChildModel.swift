import Foundation
import SwiftUI
import UserNotifications
import FamilyControls
import CryptoKit

/// Pairing details persisted in the Keychain (the secret never goes in a plain file).
struct ChildPairing: Codable {
    var invite: PairingInvite
}

@MainActor
final class ChildModel: ObservableObject {
    static let shared = ChildModel()

    // MARK: Published state

    @Published private(set) var pairing: ChildPairing?
    @Published private(set) var policy: Policy?
    @Published private(set) var decision: ShieldDecision = .none
    @Published private(set) var tally = UsageTally(dayKey: "")
    @Published private(set) var requests: [LocalRequest] = []
    @Published private(set) var taskEntries: [LocalTaskEntry] = []
    @Published private(set) var grantsToday: [Grant] = []
    @Published private(set) var authorization: AuthorizationState = .notDetermined
    @Published private(set) var isTestMode = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var problems: [String] = []
    @Published var selections: [UUID: FamilyActivitySelection] = [:]
    @Published private(set) var setupUnlockedUntil: Date?

    // MARK: Dependencies

    private let store: SharedStore
    private let transport: SyncTransport
    private let coordinator: EnforcementCoordinator
    private let planner: MonitoringPlanner
    private var keys: ChannelKeys?
    private var parentKey: Curve25519.Signing.PublicKey?
    private var lastStatusSent = Date.distantPast

    private static let pairingAccount = "child.pairing"
    private static let testModeKey = "oc.child.testMode"

    init(store: SharedStore = .shared, transport: SyncTransport = CloudKitTransport()) {
        self.store = store
        self.transport = transport
        self.coordinator = EnforcementCoordinator(store: store)
        self.planner = MonitoringPlanner(store: store)
    }

    // MARK: Lifecycle

    func bootstrap() async {
        isTestMode = UserDefaults.standard.bool(forKey: Self.testModeKey)
        loadPairing()
        reloadFromStore()
        refreshAuthorization()
        await requestNotificationPermission()
        await syncNow()
    }

    private func loadPairing() {
        guard let data = Keychain.get(account: Self.pairingAccount),
              let saved = try? JSONDecoder().decode(ChildPairing.self, from: data) else { return }
        configure(with: saved)
    }

    private func configure(with saved: ChildPairing) {
        pairing = saved
        keys = ChannelKeys(secret: saved.invite.secret)
        parentKey = try? Curve25519.Signing.PublicKey(rawRepresentation: saved.invite.parentPublicKey)
    }

    func reloadFromStore() {
        policy = store.policy
        selections = SelectionBook(store: store).all()
        requests = store.requestsFile.read().sorted { $0.request.createdAt > $1.request.createdAt }
        taskEntries = store.tasksFile.read()
        let current = coordinator.rolloverIfNeeded()
        tally = current
        grantsToday = store.grantsFile.read().filter { $0.dayKey == current.dayKey }.map(\.grant)
        decision = store.context?.decision ?? .none
    }

    // MARK: Pairing

    func handle(url: URL) {
        guard url.scheme == AppConfig.kidURLScheme else { return }
        _ = pair(with: url.absoluteString)
    }

    @discardableResult
    func pair(with text: String) -> Bool {
        guard let invite = PairingInvite.parse(text) else { return false }
        let saved = ChildPairing(invite: invite)
        guard let data = try? JSONEncoder().encode(saved),
              (try? Keychain.set(data, account: Self.pairingAccount)) != nil else { return false }
        // A different parent means a fresh start.
        store.processedFile.write(ProcessedState())
        configure(with: saved)
        Task { await syncNow(force: true) }
        return true
    }

    func unpair() {
        Keychain.delete(account: Self.pairingAccount)
        pairing = nil
        keys = nil
        parentKey = nil
        store.policy = nil
        store.pause = nil
        store.processedFile.write(ProcessedState())
        planner.stopAll()
        coordinator.refresh()
        reloadFromStore()
    }

    // MARK: Authorization

    func refreshAuthorization() {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved: authorization = .approved
        case .denied: authorization = .denied
        default: authorization = .notDetermined
        }
    }

    func requestAuthorization(testMode: Bool) async {
        UserDefaults.standard.set(testMode, forKey: Self.testModeKey)
        isTestMode = testMode
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: testMode ? .individual : .child)
        } catch {
            problems = ["Screen Time access wasn't granted: \(error.localizedDescription)"]
        }
        refreshAuthorization()
        applyEnforcement(forcePlan: true)
        await sendStatus(force: true)
    }

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: Setup lock

    var isSetupUnlocked: Bool {
        guard policy?.pin != nil else { return true }
        if let until = setupUnlockedUntil, until > Date() { return true }
        return false
    }

    func unlockSetup(pin: String) -> Bool {
        guard let verifier = policy?.pin else { return true }
        guard verifier.verify(pin) else { return false }
        setupUnlockedUntil = Date().addingTimeInterval(5 * 60)
        objectWillChange.send()
        return true
    }

    func lockSetup() {
        setupUnlockedUntil = nil
    }

    // MARK: Apps in groups

    func save(selection: FamilyActivitySelection, for groupID: UUID) {
        SelectionBook(store: store).save(selection, for: groupID)
        selections[groupID] = selection
        applyEnforcement(forcePlan: true)
        Task { await sendStatus(force: true) }
    }

    var groupsMissingApps: [UUID] {
        guard let policy else { return [] }
        return policy.groups.filter { group in
            guard let selection = selections[group.id] else { return true }
            return SelectionBook.isEmpty(selection)
        }.map(\.id)
    }

    // MARK: Enforcement

    func applyEnforcement(forcePlan: Bool = false) {
        guard let policy = store.policy else {
            coordinator.refresh()
            reloadFromStore()
            return
        }
        if authorization == .approved {
            problems = planner.replan(policy: policy, force: forcePlan)
        }
        coordinator.refresh()
        reloadFromStore()
    }

    // MARK: Derived values for the UI

    private var engine: PolicyEngine? {
        policy.map { PolicyEngine(policy: $0) }
    }

    func remainingMinutes(for group: AppGroup) -> Int? {
        guard let engine else { return nil }
        let input = EngineInput(now: Date(), usage: tally.minutes, grants: grantsToday)
        return engine.remainingMinutes(for: group, input: input)
    }

    func budget(for group: AppGroup) -> Int? {
        engine?.totalBudget(for: group, on: Date(), grants: grantsToday)
    }

    func used(_ group: AppGroup) -> Int { tally.minutes[group.id] ?? 0 }

    func reason(for group: AppGroup) -> ShieldReason? {
        if decision.blockAll { return decision.allowedGroupIDs.contains(group.id) ? nil : decision.blockAllReason }
        return decision.shieldedGroups[group.id]
    }

    var modeSummary: String? {
        guard let reason = decision.blockAllReason ?? decision.shieldedGroups.values.first else { return nil }
        let message = ShieldCopy.message(reason: reason, subject: nil, groupName: nil, canAsk: false)
        switch reason {
        case .focus(let name, _, let until):
            if let until { return "\(name) until \(Self.time(until))" }
            return name
        case .paused(let until, _):
            if let until { return "Paused until \(Self.time(until))" }
            return "Paused by your parent"
        default:
            return message.title
        }
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    // MARK: Requests and chores

    func askForMoreTime(in group: AppGroup) {
        submit(RequestKind.moreTime(groupID: group.id))
    }

    func askToEndFocus(_ scheduleID: UUID) { submit(.endFocus(scheduleID: scheduleID)) }
    func askToResume() { submit(.endPause) }

    private func submit(_ kind: RequestKind) {
        guard let policy, policy.childMayRequestMoreTime else { return }
        let pending = store.requestsFile.read().contains { $0.status == .pending && $0.request.kind == kind }
        guard !pending else { return }
        let request = ChildRequest(kind: kind, requestedMinutes: max(15, policy.requestStepMinutes))
        store.requestsFile.update { $0.append(LocalRequest(request: request, status: .pending)) }
        store.outboxFile.update { $0.append(OutboxItem(payload: .request(request))) }
        reloadFromStore()
        Task { await syncNow() }
    }

    func completionsToday(for task: ChoreTask) -> [LocalTaskEntry] {
        taskEntries.filter { $0.completion.taskID == task.id && $0.dayKey == tally.dayKey && $0.status != .denied }
    }

    func canComplete(_ task: ChoreTask) -> Bool {
        completionsToday(for: task).count < task.maxPerDay
    }

    func complete(_ task: ChoreTask) {
        guard canComplete(task) else { return }
        let completion = TaskCompletion(taskID: task.id)
        let entry = LocalTaskEntry(completion: completion, dayKey: tally.dayKey, status: .pending)
        store.tasksFile.update { $0.append(entry) }
        store.outboxFile.update { $0.append(OutboxItem(payload: .taskCompletion(completion))) }
        reloadFromStore()
        Task { await syncNow() }
    }

    // MARK: Sync

    func syncNow(force: Bool = false) async {
        guard let keys, let parentKey, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await subscribeIfNeeded(keys: keys)
            try await flushOutbox(keys: keys)
            try await pullFromParent(keys: keys, parentKey: parentKey)
            lastSync = Date()
        } catch {
            problems = ["Couldn't reach your parent's app: \(error.localizedDescription)"]
        }

        applyEnforcement()
        await sendStatus(force: force)
    }

    private var subscribed = false

    private func subscribeIfNeeded(keys: ChannelKeys) async throws {
        guard !subscribed else { return }
        try await transport.subscribe(
            channelID: keys.channelID, to: .parent,
            specs: [SubscriptionSpec(id: "oc-\(keys.channelID)-parent", kind: nil, alert: nil)])
        subscribed = true
    }

    private func flushOutbox(keys: ChannelKeys) async throws {
        for item in store.outboxFile.read() {
            let envelope = try EnvelopeCodec.seal(item.payload, sender: .child, keys: keys, signer: nil)
            try await transport.send(envelope)
            store.outboxFile.update { $0.removeAll { $0.id == item.id } }
        }
    }

    private func pullFromParent(keys: ChannelKeys, parentKey: Curve25519.Signing.PublicKey) async throws {
        var state = store.processedFile.read()
        // Re-read a minute of overlap: query indexes can lag, and we de-duplicate by ID.
        let envelopes = try await transport.fetch(channelID: keys.channelID, from: .parent,
                                                  after: max(0, state.watermark - 60_000))
        for envelope in envelopes where !state.seenIDs.contains(envelope.id) {
            state.seenIDs.append(envelope.id)
            state.watermark = max(state.watermark, envelope.timestamp)
            guard let payload = try? EnvelopeCodec.open(envelope, keys: keys, parentPublicKey: parentKey) else {
                store.log("dropped a message that failed verification")
                continue
            }
            apply(payload, sentAt: Date(timeIntervalSince1970: Double(envelope.timestamp) / 1000))
        }
        if state.seenIDs.count > 500 { state.seenIDs.removeFirst(state.seenIDs.count - 500) }
        store.processedFile.write(state)
    }

    private func apply(_ payload: Payload, sentAt: Date) {
        let now = Date()
        let today = DayKey.string(for: now)
        switch payload {
        case .policy(let incoming):
            if incoming.version > (store.policy?.version ?? 0) {
                store.policy = incoming
            }
        case .grant(let grant):
            // Ignore stale grants (e.g. delivered the next morning).
            guard now.timeIntervalSince(grant.issuedAt) < 6 * 3600 else { return }
            store.grantsFile.update { grants in
                if !grants.contains(where: { $0.grant.id == grant.id }) {
                    grants.append(StoredGrant(grant: grant, dayKey: today))
                }
            }
        case .pause(let pause):
            store.pause = pause
        case .scheduleOverride(let item):
            guard item.until > now else { return }
            store.overridesFile.update { list in
                if !list.contains(where: { $0.id == item.id }) { list.append(item) }
            }
        case .requestDecision(let decision):
            store.requestsFile.update { list in
                guard let index = list.firstIndex(where: { $0.id == decision.requestID }) else { return }
                list[index].status = decision.approved ? .approved : .denied
                list[index].decidedAt = decision.decidedAt
                list[index].note = decision.note
            }
            LocalNotifier.post(
                title: decision.approved ? "Request approved" : "Not this time",
                body: decision.note ?? (decision.approved ? "You've got more time." : "Your parent said no for now."),
                identifier: "decision-\(decision.requestID.uuidString)")
        case .taskDecision(let decision):
            store.tasksFile.update { list in
                guard let index = list.firstIndex(where: { $0.id == decision.completionID }) else { return }
                list[index].status = decision.approved ? .approved : .denied
            }
            if decision.approved {
                LocalNotifier.post(title: "Nice work!", body: "Your reward time was added.",
                                   identifier: "task-\(decision.completionID.uuidString)")
            }
        case .status, .request, .taskCompletion:
            break // child -> parent only
        }
    }

    // MARK: Status reports

    func sendStatus(force: Bool = false) async {
        guard let keys, let policy = store.policy else { return }
        guard force || Date().timeIntervalSince(lastStatusSent) > 15 * 60 else { return }

        let missing = groupsMissingApps.filter { $0 != AppGroup.essentialsID }

        let status = ChildStatus(
            sentAt: Date(), dayKey: tally.dayKey, authorization: authorization, isTestMode: isTestMode,
            policyVersion: policy.version, usageToday: tally.minutes,
            shieldedGroupIDs: Array(decision.shieldedGroups.keys),
            modeSummary: modeSummary, groupsMissingApps: missing,
            history: Array(store.historyFile.read().suffix(14)),
            problems: problems)
        do {
            let envelope = try EnvelopeCodec.seal(.status(status), sender: .child, keys: keys, signer: nil)
            try await transport.send(envelope)
            lastStatusSent = Date()
            await transport.prune(channelID: keys.channelID, sentBy: .child,
                                  before: Int64(Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970 * 1000))
        } catch {
            // Try again at the next sync.
        }
    }
}
