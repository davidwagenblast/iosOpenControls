import Foundation
import XCTest

enum TestCalendar {
    /// Gregorian, UTC, so results don't depend on the machine running the tests.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// 2025-01-06 is a Monday.
    static func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2025, month: 1, day: day, hour: hour, minute: minute))!
    }

    static let monday = 6
    static let tuesday = 7
    static let saturday = 11
}

extension Policy {
    func groupID(named name: String) -> UUID {
        groups.first { $0.name == name }!.id
    }
}
