import Foundation
import SwiftUI
import CryptoKit

struct ChildProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var policy: Policy
    var lastStatus: ChildStatus?
    var pause: PauseState?
    /// Grants sent recently, so "time left today" can include bonus time.
    var grantLog: [Grant] = []
    /// Policy edits waiting to be uploaded.
    var needsPush: Bool = false
    var watermark: Int64 = 0
    var seenIDs: [UUID] = []
}

struct InboxItem: Codable, Identifiable, Hashable {
    enum Content: Codable, Hashable {
        case request(ChildRequest)
        case task(TaskCompletion)
    }

    var id: UUID
    var childID: UUID
    var receivedAt: Date
    var content: Content
    var state: DecisionStatus = .pending
}

struct ParentState: Codable {
    var children: [ChildProfile] = []
    var inbox: [InboxItem] = []
}

@MainActor
final class ParentModel: ObservableObject {
    static let shared = ParentModel()

    @Published private(set) var children: [ChildProfile] = []
    @Published private(set) var inbox: [InboxItem] = []
    @Published var selectedChildID: UUID?
    @Published var lastError: String?
    @Published private(set) var isSyncing = false

    private let transport: SyncTransport
    private let signer: Curve25519.Signing.PrivateKey
    private let stateFile: JSONFile<ParentState>
    private var invites: [UUID: PairingInvite] = [:]
    private var subscribed: Set<UUID> = []
    private var pushTasks: [UUID: Task<Void, Never>] = [:]

    init(transport: SyncTransport = CloudKitTransport(), directory: URL? = nil) {
        self.transport = transport
        self.signer = Self.loadOrCreateSigner()

        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenControlsParent", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        stateFile = JSONFile(url: base.appendingPathComponent("state.json"), defaultValue: ParentState())

        let state = stateFile.read()
        children = state.children
        inbox = state.inbox
        selectedChildID = children.first?.id
        for child in children {
            if let data = Keychain.get(account: Self.inviteAccount(child.id)),
               let invite = try? JSONDecoder().decode(PairingInvite.self, from: data) {
                invites[child.id] = invite
            }
        }
    }

    private static func inviteAccount(_ id: UUID) -> String { "parent.invite.\(id.uuidString)" }

    private static func loadOrCreateSigner() -> Curve25519.Signing.PrivateKey {
        let account = "parent.signing"
        if let data = Keychain.get(account: account, synchronizable: true),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try? Keychain.set(key.rawRepresentation, account: account, synchronizable: true)
        return key
    }

    // MARK: Persistence

    private func save() {
        let snapshot = ParentState(children: children, inbox: inbox)
        stateFile.write(snapshot)
    }

    private func index(of id: UUID) -> Int? { children.firstIndex { $0.id == id } }

    func child(_ id: UUID?) -> ChildProfile? {
        guard let id else { return nil }
        return children.first { $0.id == id }
    }

    var selectedChild: ChildProfile? { child(selectedChildID) ?? children.first }

    var pendingInbox: [InboxItem] { inbox.filter { $0.state == .pending }.sorted { $0.receivedAt > $1.receivedAt } }

    // MARK: Children

    @discardableResult
    func addChild(name: String) -> PairingInvite? {
        let invite = PairingInvite.create(childName: name, parentPublicKey: signer.publicKey.rawRepresentation)
        let profile = ChildProfile(id: UUID(), name: name, policy: .starter(childName: name), needsPush: true)
        guard let data = try? JSONEncoder().encode(invite),
              (try? Keychain.set(data, account: Self.inviteAccount(profile.id))) != nil else {
            lastError = "Couldn't save the pairing key to the Keychain."
            return nil
        }
        invites[profile.id] = invite
        children.append(profile)
        selectedChildID = profile.id
        save()
        Task { await syncAll() }
        return invite
    }

    func invite(for id: UUID) -> PairingInvite? { invites[id] }

    func removeChild(_ id: UUID) {
        children.removeAll { $0.id == id }
        inbox.removeAll { $0.childID == id }
        invites[id] = nil
        Keychain.delete(account: Self.inviteAccount(id))
        if selectedChildID == id { selectedChildID = children.first?.id }
        save()
    }

    // MARK: Policy

    /// Applies an edit, bumps the version and uploads shortly after the last change.
    func updatePolicy(_ id: UUID, _ change: (inout Policy) -> Void) {
        guard let i = index(of: id) else { return }
        change(&children[i].policy)
        children[i].policy.version += 1
        children[i].policy.updatedAt = Date()
        children[i].needsPush = true
        save()

        pushTasks[id]?.cancel()
        pushTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushPolicy(id)
        }
    }

    func setPIN(_ pin: String?, for id: UUID) {
        updatePolicy(id) { $0.pin = pin.map { PinVerifier.make(pin: $0) } }
    }

    private func pushPolicy(_ id: UUID) async {
        guard let i = index(of: id), children[i].needsPush else { return }
        do {
            try await send(.policy(children[i].policy), to: id)
            if let j = index(of: id) { children[j].needsPush = false }
            save()
        } catch {
            lastError = "Couldn't upload changes yet: \(error.localizedDescription). They'll retry."
        }
    }

    // MARK: Commands

    func pause(_ id: UUID, minutes: Int?, message: String? = nil) async {
        let until = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        let state = PauseState(until: until, message: message)
        if await trySend(.pause(state), to: id), let i = index(of: id) {
            children[i].pause = state
            save()
        }
    }

    func resume(_ id: UUID) async {
        if await trySend(.pause(nil), to: id), let i = index(of: id) {
            children[i].pause = nil
            save()
        }
    }

    func giveBonus(_ id: UUID, groupID: UUID, minutes: Int, note: String? = nil) async {
        await sendGrant(Grant(groupID: groupID, minutes: minutes, source: .parentBonus, note: note), to: id)
    }

    private func sendGrant(_ grant: Grant, to id: UUID) async {
        if await trySend(.grant(grant), to: id), let i = index(of: id) {
            children[i].grantLog.append(grant)
            let cutoff = Date().addingTimeInterval(-2 * 86400)
            children[i].grantLog.removeAll { $0.issuedAt < cutoff }
            save()
        }
    }

    func bonusToday(for childID: UUID, groupID: UUID) -> Int {
        guard let child = child(childID) else { return 0 }
        let today = DayKey.string(for: Date())
        return child.grantLog
            .filter { $0.groupID == groupID && DayKey.string(for: $0.issuedAt) == today }
            .reduce(0) { $0 + $1.minutes }
    }

    // MARK: Inbox decisions

    func approve(_ item: InboxItem, minutes: Int) async {
        switch item.content {
        case .request(let request):
            switch request.kind {
            case .moreTime(let groupID):
                await sendGrant(Grant(groupID: groupID, minutes: minutes, source: .request(request.id)), to: item.childID)
            case .endFocus(let scheduleID):
                let override = ScheduleOverride(scheduleID: scheduleID,
                                                until: Date().addingTimeInterval(Double(minutes) * 60),
                                                requestID: request.id)
                await trySend(.scheduleOverride(override), to: item.childID)
            case .endPause:
                await resume(item.childID)
            }
            await trySend(.requestDecision(RequestDecision(requestID: request.id, approved: true,
                                                           grantedMinutes: minutes, decidedAt: Date(), note: nil)),
                          to: item.childID)
        case .task(let completion):
            guard let task = child(item.childID)?.policy.task(completion.taskID) else { return }
            await sendGrant(Grant(groupID: task.rewardGroupID, minutes: task.rewardMinutes,
                                  source: .task(task.id), note: task.title), to: item.childID)
            await trySend(.taskDecision(TaskDecision(completionID: completion.id, approved: true,
                                                     decidedAt: Date(), note: nil)), to: item.childID)
        }
        mark(item, as: .approved)
    }

    func deny(_ item: InboxItem, note: String? = nil) async {
        switch item.content {
        case .request(let request):
            await trySend(.requestDecision(RequestDecision(requestID: request.id, approved: false,
                                                           grantedMinutes: 0, decidedAt: Date(), note: note)),
                          to: item.childID)
        case .task(let completion):
            await trySend(.taskDecision(TaskDecision(completionID: completion.id, approved: false,
                                                     decidedAt: Date(), note: note)), to: item.childID)
        }
        mark(item, as: .denied)
    }

    private func mark(_ item: InboxItem, as state: DecisionStatus) {
        if let i = inbox.firstIndex(where: { $0.id == item.id }) {
            inbox[i].state = state
            save()
        }
    }

    // MARK: Transport

    private func keys(for id: UUID) -> ChannelKeys? {
        invites[id].map { ChannelKeys(secret: $0.secret) }
    }

    private func send(_ payload: Payload, to id: UUID) async throws {
        guard let keys = keys(for: id) else { return }
        let envelope = try EnvelopeCodec.seal(payload, sender: .parent, keys: keys, signer: signer)
        try await transport.send(envelope)
    }

    @discardableResult
    private func trySend(_ payload: Payload, to id: UUID) async -> Bool {
        do {
            try await send(payload, to: id)
            return true
        } catch {
            lastError = "Couldn't reach \(child(id)?.name ?? "your child")'s phone: \(error.localizedDescription)"
            return false
        }
    }

    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for child in children {
            do {
                try await sync(child.id)
            } catch {
                lastError = "Sync problem for \(child.name): \(error.localizedDescription)"
            }
        }
    }

    private func sync(_ id: UUID) async throws {
        guard let keys = keys(for: id), let name = child(id)?.name else { return }

        if !subscribed.contains(id) {
            try await transport.subscribe(channelID: keys.channelID, to: .child, specs: [
                SubscriptionSpec(id: "oc-\(keys.channelID)-request", kind: "request",
                                 alert: "\(name) is asking for more screen time."),
                SubscriptionSpec(id: "oc-\(keys.channelID)-task", kind: "task",
                                 alert: "\(name) finished a chore and is waiting for your OK."),
                SubscriptionSpec(id: "oc-\(keys.channelID)-alert", kind: "alert",
                                 alert: "Screen Time protection needs attention on \(name)'s phone."),
                SubscriptionSpec(id: "oc-\(keys.channelID)-status", kind: "status", alert: nil)
            ])
            subscribed.insert(id)
        }

        await pushPolicy(id)

        guard let i = index(of: id) else { return }
        let envelopes = try await transport.fetch(channelID: keys.channelID, from: .child,
                                                  after: max(0, children[i].watermark - 60_000))
        for envelope in envelopes {
            guard let j = index(of: id), !children[j].seenIDs.contains(envelope.id) else { continue }
            children[j].seenIDs.append(envelope.id)
            children[j].watermark = max(children[j].watermark, envelope.timestamp)
            guard let payload = try? EnvelopeCodec.open(envelope, keys: keys, parentPublicKey: nil) else { continue }
            handle(payload, from: id)
        }
        if let j = index(of: id), children[j].seenIDs.count > 500 {
            children[j].seenIDs.removeFirst(children[j].seenIDs.count - 500)
        }
        save()
        await transport.prune(channelID: keys.channelID, sentBy: .parent,
                              before: Int64(Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970 * 1000))
    }

    private func handle(_ payload: Payload, from id: UUID) {
        guard let i = index(of: id) else { return }
        switch payload {
        case .status(let status):
            if children[i].lastStatus == nil || status.sentAt >= (children[i].lastStatus?.sentAt ?? .distantPast) {
                children[i].lastStatus = status
            }
        case .request(let request):
            if !inbox.contains(where: { $0.id == request.id }) {
                inbox.append(InboxItem(id: request.id, childID: id, receivedAt: request.createdAt, content: .request(request)))
            }
        case .taskCompletion(let completion):
            if !inbox.contains(where: { $0.id == completion.id }) {
                inbox.append(InboxItem(id: completion.id, childID: id, receivedAt: completion.completedAt, content: .task(completion)))
            }
        default:
            break // parent -> child kinds
        }
    }
}
