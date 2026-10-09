import Foundation
import UserNotifications

/// The single place that turns stored state into shields. It is *idempotent*: every
/// trigger (app launch, a policy arriving, a DeviceActivity callback in an extension)
/// just calls `refresh()`, which recomputes the desired state from scratch.
final class EnforcementCoordinator {
    let store: SharedStore
    private let applier = ShieldApplier()

    init(store: SharedStore = .shared) {
        self.store = store
    }

    @discardableResult
    func refresh(now: Date = Date(), calendar: Calendar = .current) -> ShieldDecision {
        guard let policy = store.policy else {
            applier.clear()
            store.context = nil
            return .none
        }

        let tally = rolloverIfNeeded(now: now, calendar: calendar)
        let grants = store.grantsFile.read().filter { $0.dayKey == tally.dayKey }.map(\.grant)
        let overrides = store.overridesFile.read().filter { $0.until > now }

        let engine = PolicyEngine(policy: policy, calendar: calendar)
        let decision = engine.decide(EngineInput(now: now, usage: tally.minutes, grants: grants,
                                                 overrides: overrides, pause: store.pause))
        applier.apply(decision, selections: SelectionBook(store: store).all(), tamperProtection: policy.tamperProtection)

        store.context = ShieldContext(
            decision: decision,
            askEnabled: policy.childMayRequestMoreTime,
            askMinutes: policy.requestStepMinutes,
            groupNames: Dictionary(uniqueKeysWithValues: policy.groups.map { ($0.id, $0.name) }),
            updatedAt: now)
        return decision
    }

    /// Starts a fresh tally when the calendar day changes, archiving yesterday's for insights.
    @discardableResult
    func rolloverIfNeeded(now: Date = Date(), calendar: Calendar = .current) -> UsageTally {
        let key = DayKey.string(for: now, calendar: calendar)
        var result = UsageTally(dayKey: key)
        var archived: DailyUsage?
        store.tallyFile.update { tally in
            if tally.dayKey != key {
                if !tally.dayKey.isEmpty, !tally.minutes.isEmpty {
                    archived = DailyUsage(dayKey: tally.dayKey, minutes: tally.minutes)
                }
                tally = UsageTally(dayKey: key)
            }
            result = tally
        }
        if let archived {
            store.historyFile.update { history in
                history.removeAll { $0.dayKey == archived.dayKey }
                history.append(archived)
                if history.count > 30 { history.removeFirst(history.count - 30) }
            }
            store.grantsFile.update { grants in grants.removeAll { $0.dayKey != key } }
            store.tasksFile.update { tasks in tasks.removeAll { $0.dayKey != key && $0.status != .pending } }
        }
        return result
    }

    /// Called from a threshold event: "group X's apps have been used for N minutes this session".
    func recordUsage(groupID: UUID, sessionMinutes: Int, now: Date = Date(), calendar: Calendar = .current) {
        rolloverIfNeeded(now: now, calendar: calendar)
        store.tallyFile.update { tally in
            let baseline = tally.baselines[groupID] ?? 0
            tally.minutes[groupID] = max(tally.minutes[groupID] ?? 0, baseline + sessionMinutes)
        }
    }

    /// Posts a "5 minutes left" nudge once per group per day.
    func notifyIfRunningLow(groupID: UUID, now: Date = Date(), calendar: Calendar = .current) {
        guard let policy = store.policy, let group = policy.group(groupID), !group.isEssentials else { return }
        let tally = store.tallyFile.read()
        guard !tally.warned.contains(groupID) else { return }

        let grants = store.grantsFile.read().filter { $0.dayKey == tally.dayKey }.map(\.grant)
        let engine = PolicyEngine(policy: policy, calendar: calendar)
        let input = EngineInput(now: now, usage: tally.minutes, grants: grants)
        guard let remaining = engine.remainingMinutes(for: group, input: input), remaining > 0, remaining <= 5 else { return }

        store.tallyFile.update { $0.warned.insert(groupID) }
        LocalNotifier.post(title: "\(remaining) minutes of \(group.name) left",
                           body: "Wrap up what you're doing — you can ask for more time if you really need it.",
                           identifier: "lowtime-\(groupID.uuidString)")
    }
}

enum LocalNotifier {
    static func post(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
