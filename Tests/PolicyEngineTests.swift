import XCTest

final class PolicyEngineTests: XCTestCase {
    private let cal = TestCalendar.utc
    private var policy: Policy!
    private var engine: PolicyEngine!

    override func setUp() {
        super.setUp()
        policy = Policy.starter(childName: "Sam")
        engine = PolicyEngine(policy: policy, calendar: cal)
    }

    private func decide(day: Int, hour: Int, minute: Int = 0, usage: [UUID: Int] = [:], grants: [Grant] = [],
                        overrides: [ScheduleOverride] = [], pause: PauseState? = nil) -> ShieldDecision {
        engine.decide(EngineInput(now: TestCalendar.date(day: day, hour: hour, minute: minute),
                                  usage: usage, grants: grants, overrides: overrides, pause: pause))
    }

    // MARK: Schedules

    func testBedtimeRunsOvernight() {
        XCTAssertTrue(decide(day: TestCalendar.monday, hour: 22).blockAll)
        XCTAssertTrue(decide(day: TestCalendar.tuesday, hour: 6, minute: 30).blockAll, "still bedtime the next morning")
        XCTAssertFalse(decide(day: TestCalendar.tuesday, hour: 7).blockAll, "bedtime ends at 7:00")
        XCTAssertFalse(decide(day: TestCalendar.tuesday, hour: 16).blockAll)
    }

    func testSchoolOnlyOnSchoolDays() {
        let learning = policy.groupID(named: "Learning")
        let monday = decide(day: TestCalendar.monday, hour: 10)
        XCTAssertTrue(monday.blockAll)
        XCTAssertTrue(monday.allowedGroupIDs.contains(learning))
        XCTAssertTrue(monday.allowedGroupIDs.contains(AppGroup.essentialsID))
        XCTAssertFalse(decide(day: TestCalendar.saturday, hour: 10).blockAll)
    }

    func testOvernightWindowUsesStartDay() {
        // Bedtime only on Friday nights (weekday 6): ends Saturday morning, not Friday morning.
        policy.schedules = [FocusSchedule(name: "Friday night", symbol: "moon", start: TimeOfDay(hour: 22),
                                          end: TimeOfDay(hour: 6), weekdays: [6])]
        engine = PolicyEngine(policy: policy, calendar: cal)
        XCTAssertFalse(decide(day: 10, hour: 5).blockAll, "Friday 5am belongs to Thursday's window, which isn't enabled")
        XCTAssertTrue(decide(day: 10, hour: 23).blockAll, "Friday 11pm")
        XCTAssertTrue(decide(day: 11, hour: 5).blockAll, "Saturday 5am is the tail of Friday's window")
    }

    func testWindDownShieldsChosenGroupsBeforeBedtime() {
        let d = decide(day: TestCalendar.monday, hour: 20, minute: 45)
        XCTAssertFalse(d.blockAll)
        XCTAssertNotNil(d.shieldedGroups[policy.groupID(named: "Games")])
        XCTAssertNotNil(d.shieldedGroups[policy.groupID(named: "Social")])
        XCTAssertNil(d.shieldedGroups[policy.groupID(named: "Learning")])
        if case .windDown? = d.shieldedGroups[policy.groupID(named: "Games")] {} else { XCTFail("expected wind-down reason") }
        XCTAssertFalse(decide(day: TestCalendar.monday, hour: 20, minute: 15).isShieldingAnything)
    }

    func testWindDownBeforeMidnightStartWrapsToPreviousDay() {
        // Focus starts 00:10 Tuesday; 30 min wind-down starts 23:40 Monday.
        let games = policy.groupID(named: "Games")
        policy.schedules = [FocusSchedule(name: "Late", symbol: "moon", start: TimeOfDay(hour: 0, minute: 10),
                                          end: TimeOfDay(hour: 6), weekdays: [3], // Tuesday
                                          windDownMinutes: 30, windDownGroupIDs: [games])]
        engine = PolicyEngine(policy: policy, calendar: cal)
        XCTAssertNotNil(decide(day: TestCalendar.monday, hour: 23, minute: 45).shieldedGroups[games])
        XCTAssertNil(decide(day: TestCalendar.tuesday, hour: 23, minute: 45).shieldedGroups[games])
    }

    func testOverlappingWindowsAllowOnlyWhatBothAllow() {
        let a = policy.groupID(named: "Games"), b = policy.groupID(named: "Learning")
        policy.schedules = [
            FocusSchedule(name: "One", symbol: "a", start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 12), allowedGroupIDs: [a, b]),
            FocusSchedule(name: "Two", symbol: "b", start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 11), allowedGroupIDs: [b])
        ]
        engine = PolicyEngine(policy: policy, calendar: cal)
        let d = decide(day: TestCalendar.saturday, hour: 10, minute: 30)
        XCTAssertEqual(d.allowedGroupIDs, [b, AppGroup.essentialsID])
    }

    func testScheduleOverrideLiftsUntilExpiry() {
        let bedtime = policy.schedules.first { $0.name == "Bedtime" }!
        let override = ScheduleOverride(scheduleID: bedtime.id, until: TestCalendar.date(day: TestCalendar.monday, hour: 22, minute: 30))
        XCTAssertFalse(decide(day: TestCalendar.monday, hour: 22, overrides: [override]).blockAll)
        XCTAssertTrue(decide(day: TestCalendar.monday, hour: 22, minute: 45, overrides: [override]).blockAll)
    }

    func testDisabledScheduleIsIgnored() {
        policy.schedules[0].isEnabled = false // Bedtime
        engine = PolicyEngine(policy: policy, calendar: cal)
        XCTAssertFalse(decide(day: TestCalendar.monday, hour: 22).blockAll)
    }

    // MARK: Limits

    func testLimitShieldsGroupOnceBudgetIsUsed() {
        let games = policy.groupID(named: "Games")
        XCTAssertNil(decide(day: TestCalendar.monday, hour: 16, usage: [games: 55]).shieldedGroups[games])
        let d = decide(day: TestCalendar.monday, hour: 16, usage: [games: 60])
        guard case .limitReached(let used, let budget)? = d.shieldedGroups[games] else { return XCTFail("expected limit") }
        XCTAssertEqual(used, 60)
        XCTAssertEqual(budget, 60)
        XCTAssertFalse(d.blockAll)
    }

    func testWeekendBudgetIsLarger() {
        let games = policy.groupID(named: "Games")
        XCTAssertNil(decide(day: TestCalendar.saturday, hour: 16, usage: [games: 90]).shieldedGroups[games])
        XCTAssertNotNil(decide(day: TestCalendar.saturday, hour: 16, usage: [games: 120]).shieldedGroups[games])
    }

    func testGrantsExtendTheBudget() {
        let games = policy.groupID(named: "Games")
        let grant = Grant(groupID: games, minutes: 15, source: .parentBonus)
        XCTAssertNil(decide(day: TestCalendar.monday, hour: 16, usage: [games: 60], grants: [grant]).shieldedGroups[games])
        XCTAssertNotNil(decide(day: TestCalendar.monday, hour: 16, usage: [games: 75], grants: [grant]).shieldedGroups[games])
    }

    func testGrantForOneGroupDoesNotLeakToAnother() {
        let games = policy.groupID(named: "Games"), social = policy.groupID(named: "Social")
        let grant = Grant(groupID: games, minutes: 30, source: .parentBonus)
        XCTAssertNotNil(decide(day: TestCalendar.monday, hour: 16, usage: [social: 45], grants: [grant]).shieldedGroups[social])
    }

    func testZeroBudgetBlocksImmediately() {
        let games = policy.groupID(named: "Games")
        policy.groups[policy.groups.firstIndex { $0.id == games }!].budget = .uniform(0)
        engine = PolicyEngine(policy: policy, calendar: cal)
        XCTAssertNotNil(decide(day: TestCalendar.monday, hour: 16).shieldedGroups[games])
    }

    func testUnlimitedAndEssentialsAreNeverShieldedByLimits() {
        let learning = policy.groupID(named: "Learning")
        let d = decide(day: TestCalendar.monday, hour: 16, usage: [learning: 9999, AppGroup.essentialsID: 9999])
        XCTAssertFalse(d.isShieldingAnything)
    }

    func testLimitedGroupInsideSchoolIsNotAllowedEvenIfListed() {
        let learning = policy.groupID(named: "Learning")
        policy.groups[policy.groups.firstIndex { $0.id == learning }!].budget = .uniform(30)
        engine = PolicyEngine(policy: policy, calendar: cal)
        let d = decide(day: TestCalendar.monday, hour: 10, usage: [learning: 30])
        XCTAssertTrue(d.blockAll)
        XCTAssertFalse(d.allowedGroupIDs.contains(learning), "out of time beats the school allow-list")
    }

    // MARK: Pause

    func testPauseBlocksEverythingButEssentials() {
        let pause = PauseState(startedAt: TestCalendar.date(day: TestCalendar.monday, hour: 16),
                               until: TestCalendar.date(day: TestCalendar.monday, hour: 17), message: "Dinner")
        let d = decide(day: TestCalendar.monday, hour: 16, minute: 30, pause: pause)
        XCTAssertTrue(d.blockAll)
        XCTAssertEqual(d.allowedGroupIDs, [AppGroup.essentialsID])
        if case .paused(_, let message)? = d.blockAllReason { XCTAssertEqual(message, "Dinner") } else { XCTFail() }
        XCTAssertFalse(decide(day: TestCalendar.monday, hour: 17, minute: 1, pause: pause).blockAll, "pause expired")
    }

    func testOpenEndedPauseLastsUntilCleared() {
        let pause = PauseState(startedAt: TestCalendar.date(day: TestCalendar.monday, hour: 16), until: nil)
        XCTAssertTrue(decide(day: TestCalendar.tuesday, hour: 3, pause: pause).blockAll)
    }

    // MARK: Budget helpers

    func testRemainingMinutes() {
        let games = policy.group(policy.groupID(named: "Games"))!
        let input = EngineInput(now: TestCalendar.date(day: TestCalendar.monday, hour: 16),
                                usage: [games.id: 20], grants: [Grant(groupID: games.id, minutes: 10, source: .parentBonus)])
        XCTAssertEqual(engine.remainingMinutes(for: games, input: input), 50)
        XCTAssertNil(engine.remainingMinutes(for: policy.group(policy.groupID(named: "Learning"))!, input: input))
    }
}
