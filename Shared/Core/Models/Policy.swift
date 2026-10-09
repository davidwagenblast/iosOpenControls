import Foundation

// MARK: - Time helpers

struct TimeOfDay: Codable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    init(minutes: Int) {
        let m = ((minutes % 1440) + 1440) % 1440
        self.hour = m / 60
        self.minute = m % 60
    }

    var minutesSinceMidnight: Int { hour * 60 + minute }
    var dateComponents: DateComponents { DateComponents(hour: hour, minute: minute) }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    func formatted(calendar: Calendar = .current) -> String {
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

/// `Calendar` weekday numbers: 1 = Sunday ... 7 = Saturday.
enum Weekday {
    static let all: [Int] = Array(1...7)
    static let schoolDays: Set<Int> = [2, 3, 4, 5, 6]
    static let weekend: Set<Int> = [1, 7]
    static let everyDay: Set<Int> = Set(1...7)

    static func shortName(_ weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols
        guard (1...symbols.count).contains(weekday) else { return "?" }
        return symbols[weekday - 1]
    }

    static func previous(_ weekday: Int) -> Int { weekday == 1 ? 7 : weekday - 1 }
}

// MARK: - Groups and budgets

/// A daily allowance per weekday. `nil` means "no limit that day".
struct DailyBudget: Codable, Hashable {
    /// Seven entries, index 0 = Sunday ... index 6 = Saturday.
    private(set) var minutesByWeekday: [Int?]

    init(minutesByWeekday: [Int?]) {
        var normalized = Array(minutesByWeekday.prefix(7))
        while normalized.count < 7 { normalized.append(nil) }
        self.minutesByWeekday = normalized
    }

    static func uniform(_ minutes: Int?) -> DailyBudget {
        DailyBudget(minutesByWeekday: Array(repeating: minutes, count: 7))
    }

    static func split(schoolDays: Int?, weekend: Int?) -> DailyBudget {
        DailyBudget(minutesByWeekday: Weekday.all.map { Weekday.weekend.contains($0) ? weekend : schoolDays })
    }

    func minutes(forWeekday weekday: Int) -> Int? {
        guard (1...7).contains(weekday) else { return nil }
        return minutesByWeekday[weekday - 1]
    }

    mutating func set(_ minutes: Int?, forWeekday weekday: Int) {
        guard (1...7).contains(weekday) else { return }
        minutesByWeekday[weekday - 1] = minutes
    }

    var isUnlimited: Bool { minutesByWeekday.allSatisfy { $0 == nil } }

    /// Largest finite daily limit, used to size the monitoring plan.
    var largestLimit: Int? { minutesByWeekday.compactMap { $0 }.max() }
}

enum GroupColor: String, Codable, CaseIterable, Hashable {
    case blue, green, orange, pink, purple, red, teal, indigo, gray
}

/// A named set of apps/categories/websites. *Which* apps belong to a group is chosen
/// on the child's device (Screen Time tokens are opaque and device-local); the
/// parent controls everything else about the group from afar.
struct AppGroup: Codable, Identifiable, Hashable {
    static let essentialsID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var id: UUID
    var name: String
    var symbol: String
    var color: GroupColor
    var budget: DailyBudget

    var isEssentials: Bool { id == AppGroup.essentialsID }

    init(id: UUID = UUID(), name: String, symbol: String, color: GroupColor, budget: DailyBudget = .uniform(nil)) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.budget = budget
    }

    static func essentials() -> AppGroup {
        AppGroup(id: essentialsID, name: "Essentials", symbol: "phone.fill", color: .gray)
    }
}

// MARK: - Focus schedules

/// A recurring window (bedtime, school, homework) during which everything except an
/// allow-list of groups is shielded. An optional wind-down phase shields chosen
/// groups for a while *before* the window starts.
struct FocusSchedule: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var start: TimeOfDay
    var end: TimeOfDay
    /// Weekdays on which the window *starts* (so an overnight window that starts Friday ends Saturday).
    var weekdays: Set<Int>
    /// Groups that stay usable during the window. Essentials are always allowed.
    var allowedGroupIDs: Set<UUID>
    var windDownMinutes: Int
    var windDownGroupIDs: Set<UUID>
    var isEnabled: Bool
    /// Whether the child can ask the parent to end this window early.
    var allowsEarlyExitRequests: Bool

    init(id: UUID = UUID(), name: String, symbol: String, start: TimeOfDay, end: TimeOfDay,
         weekdays: Set<Int> = Weekday.everyDay, allowedGroupIDs: Set<UUID> = [],
         windDownMinutes: Int = 0, windDownGroupIDs: Set<UUID> = [],
         isEnabled: Bool = true, allowsEarlyExitRequests: Bool = true) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.start = start
        self.end = end
        self.weekdays = weekdays
        self.allowedGroupIDs = allowedGroupIDs
        self.windDownMinutes = windDownMinutes
        self.windDownGroupIDs = windDownGroupIDs
        self.isEnabled = isEnabled
        self.allowsEarlyExitRequests = allowsEarlyExitRequests
    }
}

// MARK: - Earn-time chores

/// Something the child can do to earn extra minutes in a group.
struct ChoreTask: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var symbol: String
    var rewardMinutes: Int
    var rewardGroupID: UUID
    var maxPerDay: Int
    var isEnabled: Bool

    init(id: UUID = UUID(), title: String, symbol: String = "checkmark.circle.fill",
         rewardMinutes: Int, rewardGroupID: UUID, maxPerDay: Int = 1, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.rewardMinutes = rewardMinutes
        self.rewardGroupID = rewardGroupID
        self.maxPerDay = maxPerDay
        self.isEnabled = isEnabled
    }
}

// MARK: - Policy

/// Everything the parent configures for one child. Versioned so the child always
/// keeps the newest copy, no matter what order messages arrive in.
struct Policy: Codable, Hashable {
    var version: Int
    var updatedAt: Date
    var childName: String
    var groups: [AppGroup]
    var schedules: [FocusSchedule]
    var tasks: [ChoreTask]
    /// Gate for the "parent setup" area on the child's device.
    var pin: PinVerifier?
    var childMayRequestMoreTime: Bool
    /// Default amount offered when the child asks for more time.
    var requestStepMinutes: Int
    /// Locks automatic date & time and app deletion while the child app is authorized.
    var tamperProtection: Bool

    func group(_ id: UUID) -> AppGroup? { groups.first { $0.id == id } }
    func schedule(_ id: UUID) -> FocusSchedule? { schedules.first { $0.id == id } }
    func task(_ id: UUID) -> ChoreTask? { tasks.first { $0.id == id } }

    var limitedGroups: [AppGroup] { groups.filter { !$0.isEssentials && !$0.budget.isUnlimited } }

    /// A sensible starting point a parent can tweak.
    static func starter(childName: String) -> Policy {
        let games = AppGroup(name: "Games", symbol: "gamecontroller.fill", color: .purple,
                             budget: .split(schoolDays: 60, weekend: 120))
        let social = AppGroup(name: "Social", symbol: "bubble.left.and.bubble.right.fill", color: .pink,
                              budget: .split(schoolDays: 45, weekend: 90))
        let video = AppGroup(name: "Video", symbol: "play.rectangle.fill", color: .red,
                             budget: .split(schoolDays: 60, weekend: 120))
        let learning = AppGroup(name: "Learning", symbol: "book.fill", color: .green)
        let essentials = AppGroup.essentials()

        let bedtime = FocusSchedule(
            name: "Bedtime", symbol: "moon.stars.fill",
            start: TimeOfDay(hour: 21), end: TimeOfDay(hour: 7),
            allowedGroupIDs: [], windDownMinutes: 30,
            windDownGroupIDs: [games.id, social.id, video.id])
        let school = FocusSchedule(
            name: "School", symbol: "graduationcap.fill",
            start: TimeOfDay(hour: 8, minute: 30), end: TimeOfDay(hour: 15),
            weekdays: Weekday.schoolDays, allowedGroupIDs: [learning.id])

        let reading = ChoreTask(title: "Read for 20 minutes", symbol: "book.closed.fill",
                                rewardMinutes: 15, rewardGroupID: games.id)
        let tidy = ChoreTask(title: "Tidy your room", symbol: "bed.double.fill",
                             rewardMinutes: 15, rewardGroupID: video.id)

        return Policy(version: 1, updatedAt: Date(), childName: childName,
                      groups: [essentials, games, social, video, learning],
                      schedules: [bedtime, school], tasks: [reading, tidy],
                      pin: nil, childMayRequestMoreTime: true, requestStepMinutes: 15,
                      tamperProtection: true)
    }
}
