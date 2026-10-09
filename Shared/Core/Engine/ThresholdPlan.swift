import Foundation

/// DeviceActivity can only tell us "this selection reached N minutes today" via events
/// we register up front. This describes which N's we register, and how the event and
/// activity names round-trip.
///
/// Granularity: every 5 minutes up to 2 hours, every 15 minutes after that. Budgets
/// that sit on that grid are enforced exactly; anything else is enforced at the next
/// grid point at or above it.
enum ThresholdPlan {
    static let maxMinutes = 480
    static let fineLimit = 120

    static func steps(upTo cap: Int) -> [Int] {
        let capped = min(max(cap, 5), maxMinutes)
        var out: [Int] = []
        var m = 5
        while m <= min(capped, fineLimit) {
            out.append(m)
            m += 5
        }
        m = fineLimit + 15
        while m <= capped {
            out.append(m)
            m += 15
        }
        return out
    }

    /// How far to monitor for a group: its largest daily limit plus headroom for grants.
    static func cap(for group: AppGroup) -> Int {
        if let largest = group.budget.largestLimit { return min(maxMinutes, largest + 120) }
        return 240 // unlimited groups are still tracked for insights
    }

    static func stepSize(at minutes: Int) -> Int { minutes >= fineLimit ? 15 : 5 }
    static func stepUp(_ minutes: Int) -> Int { min(maxMinutes, minutes + stepSize(at: minutes)) }
    static func stepDown(_ minutes: Int) -> Int { max(0, minutes - stepSize(at: minutes - 1)) }

    // MARK: Names

    static let groupActivityPrefix = "group."
    static let focusActivityPrefix = "focus."
    static let windDownActivityPrefix = "winddown."
    static let pauseActivity = "pause"
    static let overrideActivityPrefix = "override."

    static func groupActivity(_ id: UUID) -> String { groupActivityPrefix + id.uuidString }
    static func focusActivity(_ id: UUID) -> String { focusActivityPrefix + id.uuidString }
    static func windDownActivity(_ id: UUID) -> String { windDownActivityPrefix + id.uuidString }
    static func overrideActivity(_ id: UUID) -> String { overrideActivityPrefix + id.uuidString }

    static func eventName(group: UUID, minutes: Int) -> String { "\(group.uuidString)|\(minutes)" }

    static func parseEvent(_ name: String) -> (group: UUID, minutes: Int)? {
        let parts = name.split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let m = Int(parts[1]) else { return nil }
        return (id, m)
    }

    static func parseGroupActivity(_ name: String) -> UUID? {
        guard name.hasPrefix(groupActivityPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(groupActivityPrefix.count)))
    }
}
