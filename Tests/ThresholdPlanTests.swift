import XCTest

final class ThresholdPlanTests: XCTestCase {
    func testStepsAreFiveMinutesThenFifteen() {
        let steps = ThresholdPlan.steps(upTo: 150)
        XCTAssertEqual(steps.first, 5)
        XCTAssertTrue(steps.contains(115))
        XCTAssertTrue(steps.contains(120))
        XCTAssertFalse(steps.contains(125))
        XCTAssertTrue(steps.contains(135))
        XCTAssertEqual(steps.last, 150)
    }

    func testStepsAreCappedAndSorted() {
        let steps = ThresholdPlan.steps(upTo: 10_000)
        XCTAssertEqual(steps.last, 480)
        XCTAssertEqual(steps, steps.sorted())
        XCTAssertEqual(Set(steps).count, steps.count)
        XCTAssertLessThanOrEqual(steps.count, 60, "keep the number of registered events modest")
    }

    func testSteppingFollowsTheGrid() {
        XCTAssertEqual(ThresholdPlan.stepUp(60), 65)
        XCTAssertEqual(ThresholdPlan.stepUp(120), 135)
        XCTAssertEqual(ThresholdPlan.stepDown(135), 120)
        XCTAssertEqual(ThresholdPlan.stepDown(120), 115)
        XCTAssertEqual(ThresholdPlan.stepDown(0), 0)
        XCTAssertEqual(ThresholdPlan.stepUp(480), 480)
    }

    func testEveryStepIsReachableByStepping() {
        var m = 0
        var seen: [Int] = []
        while m < 480 { m = ThresholdPlan.stepUp(m); seen.append(m) }
        XCTAssertEqual(seen, ThresholdPlan.steps(upTo: 480))
    }

    func testCapLeavesHeadroomForGrants() {
        let group = AppGroup(name: "Games", symbol: "g", color: .blue, budget: .split(schoolDays: 60, weekend: 120))
        XCTAssertEqual(ThresholdPlan.cap(for: group), 240)
        XCTAssertEqual(ThresholdPlan.cap(for: AppGroup(name: "Free", symbol: "f", color: .blue)), 240)
    }

    func testEventAndActivityNamesRoundTrip() {
        let id = UUID()
        let parsed = ThresholdPlan.parseEvent(ThresholdPlan.eventName(group: id, minutes: 45))
        XCTAssertEqual(parsed?.group, id)
        XCTAssertEqual(parsed?.minutes, 45)
        XCTAssertNil(ThresholdPlan.parseEvent("garbage"))
        XCTAssertEqual(ThresholdPlan.parseGroupActivity(ThresholdPlan.groupActivity(id)), id)
        XCTAssertNil(ThresholdPlan.parseGroupActivity(ThresholdPlan.focusActivity(id)))
    }
}
