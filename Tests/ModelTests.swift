import XCTest

final class ModelTests: XCTestCase {
    func testStarterPolicyIsInternallyConsistent() {
        let policy = Policy.starter(childName: "Sam")
        let ids = Set(policy.groups.map(\.id))
        XCTAssertEqual(ids.count, policy.groups.count)
        XCTAssertTrue(ids.contains(AppGroup.essentialsID))
        for schedule in policy.schedules {
            XCTAssertTrue(schedule.allowedGroupIDs.isSubset(of: ids))
            XCTAssertTrue(schedule.windDownGroupIDs.isSubset(of: ids))
            XCTAssertGreaterThanOrEqual(schedule.focusWindow?.durationMinutes ?? 0, 15)
        }
        for task in policy.tasks { XCTAssertTrue(ids.contains(task.rewardGroupID)) }
    }

    func testDailyBudgetByWeekday() {
        var budget = DailyBudget.split(schoolDays: 60, weekend: 120)
        XCTAssertEqual(budget.minutes(forWeekday: 1), 120) // Sunday
        XCTAssertEqual(budget.minutes(forWeekday: 2), 60)  // Monday
        XCTAssertEqual(budget.minutes(forWeekday: 7), 120) // Saturday
        XCTAssertEqual(budget.largestLimit, 120)
        budget.set(nil, forWeekday: 2)
        XCTAssertNil(budget.minutes(forWeekday: 2))
        XCTAssertFalse(budget.isUnlimited)
        XCTAssertTrue(DailyBudget.uniform(nil).isUnlimited)
        XCTAssertNil(budget.minutes(forWeekday: 0))
    }

    func testDailyBudgetCodableKeepsNilDays() throws {
        let budget = DailyBudget(minutesByWeekday: [nil, 30, nil, 45, nil, nil, 90])
        let data = try JSONEncoder().encode(budget)
        XCTAssertEqual(try JSONDecoder().decode(DailyBudget.self, from: data), budget)
    }

    func testTimeOfDayWraps() {
        XCTAssertEqual(TimeOfDay(minutes: -30), TimeOfDay(hour: 23, minute: 30))
        XCTAssertEqual(TimeOfDay(minutes: 1500), TimeOfDay(hour: 1))
        XCTAssertLessThan(TimeOfDay(hour: 8), TimeOfDay(hour: 9))
    }

    func testPauseActivity() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let pause = PauseState(startedAt: start, until: start.addingTimeInterval(600))
        XCTAssertTrue(pause.isActive(at: start.addingTimeInterval(1)))
        XCTAssertFalse(pause.isActive(at: start.addingTimeInterval(601)))
    }

    func testDayKey() {
        XCTAssertEqual(DayKey.string(for: TestCalendar.date(day: 6, hour: 23, minute: 59), calendar: TestCalendar.utc), "2025-01-06")
        XCTAssertEqual(DayKey.string(for: TestCalendar.date(day: 7, hour: 0), calendar: TestCalendar.utc), "2025-01-07")
    }

    func testMinutesFormatting() {
        XCTAssertEqual(MinutesFormat.short(75), "1 h 15 m")
        XCTAssertEqual(MinutesFormat.short(45), "45 m")
        XCTAssertEqual(MinutesFormat.short(120), "2 h")
        XCTAssertEqual(MinutesFormat.long(1), "1 minute")
        XCTAssertEqual(MinutesFormat.long(90), "1 hour 30 minutes")
    }

    func testShieldCopyOffersAskButtonOnlyWhenAllowed() {
        let limit = ShieldReason.limitReached(minutesUsed: 60, budget: 60)
        XCTAssertNotNil(ShieldCopy.message(reason: limit, subject: "Roblox", groupName: "Games", canAsk: true).askLabel)
        XCTAssertNil(ShieldCopy.message(reason: limit, subject: "Roblox", groupName: "Games", canAsk: false).askLabel)
        XCTAssertNil(ShieldCopy.message(reason: nil, subject: nil, groupName: nil, canAsk: true).askLabel)
    }

    func testJSONFileCoordinatesReadModifyWrite() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = JSONFile<[Int]>(url: dir.appendingPathComponent("n.json"), defaultValue: [])
        XCTAssertEqual(file.read(), [])
        file.update { $0.append(1) }
        file.update { $0.append(2) }
        XCTAssertEqual(file.read(), [1, 2])
    }

    func testSharedStoreRoundTrips() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SharedStore(directory: dir)
        XCTAssertNil(store.policy)
        var policy = Policy.starter(childName: "Sam")
        policy.updatedAt = Date(timeIntervalSince1970: 1_750_000_000) // JSON dates are whole seconds
        store.policy = policy
        XCTAssertEqual(store.policy, policy)
        store.policy = nil
        XCTAssertNil(store.policy)

        let request = ChildRequest(kind: .endPause, requestedMinutes: 15)
        store.outboxFile.update { $0.append(OutboxItem(payload: .request(request))) }
        XCTAssertEqual(store.outboxFile.read().count, 1)
    }
}
