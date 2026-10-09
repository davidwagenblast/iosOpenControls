import Foundation

// MARK: - Day keys

enum DayKey {
    /// `yyyy-MM-dd` in the supplied calendar's time zone.
    static func string(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Windows

/// A recurring span that starts at `startMinute` on any of `weekdays` and lasts
/// `durationMinutes`, possibly running past midnight into the next day.
struct ScheduleWindow: Hashable {
    var startMinute: Int
    var durationMinutes: Int
    var weekdays: Set<Int>

    func isActive(at date: Date, calendar: Calendar) -> Bool {
        guard durationMinutes > 0 else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
        let now = hour * 60 + minute

        // Window that started earlier today.
        if weekdays.contains(weekday), now >= startMinute, now - startMinute < durationMinutes {
            return true
        }
        // Window that started yesterday and runs past midnight.
        if weekdays.contains(Weekday.previous(weekday)) {
            let sinceStart = now + 1440 - startMinute
            if sinceStart >= 0, sinceStart < durationMinutes { return true }
        }
        return false
    }
}

extension FocusSchedule {
    var focusWindow: ScheduleWindow? {
        let duration = (end.minutesSinceMidnight - start.minutesSinceMidnight + 1440) % 1440
        guard duration > 0 else { return nil }
        return ScheduleWindow(startMinute: start.minutesSinceMidnight, durationMinutes: duration, weekdays: weekdays)
    }

    var windDownWindow: ScheduleWindow? {
        guard windDownMinutes > 0, !windDownGroupIDs.isEmpty else { return nil }
        let raw = start.minutesSinceMidnight - windDownMinutes
        let days: Set<Int> = raw < 0 ? Set(weekdays.map(Weekday.previous)) : weekdays
        return ScheduleWindow(startMinute: (raw + 1440) % 1440, durationMinutes: windDownMinutes, weekdays: days)
    }
}

// MARK: - Decision

enum ShieldReason: Codable, Hashable {
    case limitReached(minutesUsed: Int, budget: Int)
    case focus(name: String, scheduleID: UUID, until: Date?)
    case windDown(name: String, scheduleID: UUID, focusStartsAt: TimeOfDay)
    case paused(until: Date?, message: String?)
}

/// What should be shielded right now. Pure data so it can be tested, stored for the
/// shield UI extensions, and applied by `ShieldApplier`.
struct ShieldDecision: Codable, Hashable {
    /// Shield everything except `allowedGroupIDs`.
    var blockAll: Bool = false
    var blockAllReason: ShieldReason?
    var allowedGroupIDs: Set<UUID> = []
    /// Individual groups shielded (limit reached / wind-down). Unused when `blockAll` is on.
    var shieldedGroups: [UUID: ShieldReason] = [:]

    static let none = ShieldDecision()

    var isShieldingAnything: Bool { blockAll || !shieldedGroups.isEmpty }

    fileprivate mutating func normalize() {
        if blockAll {
            allowedGroupIDs.insert(AppGroup.essentialsID)
            allowedGroupIDs.subtract(shieldedGroups.keys)
        } else {
            allowedGroupIDs = []
        }
    }
}

struct EngineInput {
    var now: Date
    /// Minutes used today, per group.
    var usage: [UUID: Int]
    /// Grants that apply to today.
    var grants: [Grant]
    var overrides: [ScheduleOverride]
    var pause: PauseState?

    init(now: Date, usage: [UUID: Int] = [:], grants: [Grant] = [],
         overrides: [ScheduleOverride] = [], pause: PauseState? = nil) {
        self.now = now
        self.usage = usage
        self.grants = grants
        self.overrides = overrides
        self.pause = pause
    }
}

struct PolicyEngine {
    var policy: Policy
    var calendar: Calendar = .current

    // MARK: Budgets

    func baseBudget(for group: AppGroup, on date: Date) -> Int? {
        group.budget.minutes(forWeekday: calendar.component(.weekday, from: date))
    }

    /// Daily allowance including today's grants. `nil` = unlimited.
    func totalBudget(for group: AppGroup, on date: Date, grants: [Grant]) -> Int? {
        guard !group.isEssentials, let base = baseBudget(for: group, on: date) else { return nil }
        let bonus = grants.filter { $0.groupID == group.id }.reduce(0) { $0 + $1.minutes }
        return max(0, base + bonus)
    }

    func remainingMinutes(for group: AppGroup, input: EngineInput) -> Int? {
        guard let total = totalBudget(for: group, on: input.now, grants: input.grants) else { return nil }
        return max(0, total - (input.usage[group.id] ?? 0))
    }

    // MARK: Schedules

    func activeFocusSchedules(at date: Date, overrides: [ScheduleOverride] = []) -> [FocusSchedule] {
        let lifted = Set(overrides.filter { $0.until > date }.map(\.scheduleID))
        return policy.schedules.filter {
            $0.isEnabled && !lifted.contains($0.id) && $0.focusWindow?.isActive(at: date, calendar: calendar) == true
        }
    }

    /// The next time the schedule's window ends, for "back at 7:00 AM" messaging.
    func nextEnd(of schedule: FocusSchedule, after date: Date) -> Date? {
        calendar.nextDate(after: date, matching: schedule.end.dateComponents, matchingPolicy: .nextTime)
    }

    // MARK: Decision

    func decide(_ input: EngineInput) -> ShieldDecision {
        var decision = ShieldDecision()
        let now = input.now
        let essentials = AppGroup.essentialsID

        // 1. A parent pause beats everything.
        if let pause = input.pause, pause.isActive(at: now) {
            decision.blockAll = true
            decision.blockAllReason = .paused(until: pause.until, message: pause.message)
            decision.allowedGroupIDs = [essentials]
            decision.normalize()
            return decision
        }

        // 2. Focus windows (block all but an allow-list) and wind-down phases (block some groups).
        let lifted = Set(input.overrides.filter { $0.until > now }.map(\.scheduleID))
        var allowLists: [Set<UUID>] = []
        for schedule in policy.schedules where schedule.isEnabled && !lifted.contains(schedule.id) {
            if schedule.focusWindow?.isActive(at: now, calendar: calendar) == true {
                allowLists.append(schedule.allowedGroupIDs.union([essentials]))
                if decision.blockAllReason == nil {
                    decision.blockAllReason = .focus(name: schedule.name, scheduleID: schedule.id,
                                                     until: nextEnd(of: schedule, after: now))
                }
            } else if schedule.windDownWindow?.isActive(at: now, calendar: calendar) == true {
                for id in schedule.windDownGroupIDs where id != essentials && decision.shieldedGroups[id] == nil {
                    decision.shieldedGroups[id] = .windDown(name: schedule.name, scheduleID: schedule.id,
                                                            focusStartsAt: schedule.start)
                }
            }
        }
        if let first = allowLists.first {
            decision.blockAll = true
            // Overlapping windows: only what *every* active window allows stays open.
            decision.allowedGroupIDs = allowLists.dropFirst().reduce(first) { $0.intersection($1) }
        }

        // 3. Daily limits.
        for group in policy.groups where !group.isEssentials {
            guard let budget = totalBudget(for: group, on: now, grants: input.grants) else { continue }
            let used = input.usage[group.id] ?? 0
            if used >= budget, decision.shieldedGroups[group.id] == nil {
                decision.shieldedGroups[group.id] = .limitReached(minutesUsed: used, budget: budget)
            }
        }

        decision.normalize()
        return decision
    }
}
