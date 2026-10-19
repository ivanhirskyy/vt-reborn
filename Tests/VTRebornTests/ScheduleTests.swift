import XCTest
@testable import VTReborn

private let schedule = [
    PunchConfig(time: "07:30", type: "in"),
    PunchConfig(time: "12:00", type: "out"),
    PunchConfig(time: "13:00", type: "in"),
    PunchConfig(time: "16:30", type: "out"),
]

/// A local wall-clock moment on 2026-10-19 (a Monday).
private func at(_ hour: Int, _ minute: Int, day: Int = 19) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func punches(_ items: (String, String)...) -> [Punch] {
    items.map { Punch(time: $0.0, type: $0.1) }
}

final class DayCompletenessTests: XCTestCase {
    func testTodayIsDueAware() {
        // 10:16 — only the 07:30 IN is due, and it's recorded.
        XCTAssertTrue(dayCoversConfiguredSchedule(
            punches: punches(("07:30", "in")), configs: schedule, isToday: true, now: at(10, 16)))
    }

    func testTodayMissedDueSlotIsPartial() {
        // 14:30 — the 13:00 IN is overdue and missing.
        XCTAssertFalse(dayCoversConfiguredSchedule(
            punches: punches(("07:30", "in"), ("12:00", "out")), configs: schedule, isToday: true, now: at(14, 30)))
    }

    func testTodayBeforeFirstSlotNeedsNothing() {
        XCTAssertTrue(dayCoversConfiguredSchedule(
            punches: punches(("07:30", "in")), configs: schedule, isToday: true, now: at(7, 0)))
    }

    func testPastDayWithBookendsIsComplete() {
        XCTAssertTrue(dayCoversConfiguredSchedule(
            punches: punches(("07:35", "in"), ("16:40", "out")), configs: schedule))
    }

    func testPastDayMissingAfternoonIsPartial() {
        XCTAssertFalse(dayCoversConfiguredSchedule(
            punches: punches(("07:30", "in"), ("12:00", "out")), configs: schedule))
    }

    func testPastDayWithOnlyInIsPartial() {
        XCTAssertFalse(dayCoversConfiguredSchedule(punches: punches(("07:30", "in")), configs: schedule))
    }

    func testEmptyDayStatus() {
        XCTAssertEqual(DayStatus(from: [], configs: schedule), .empty)
    }
}

@MainActor
final class BackfillPlanTests: XCTestCase {
    private func plan(_ existing: [(String, String)] = [], now: Date, date: Date? = nil) -> [AppModel.BackfillPlan] {
        AppModel.buildBackfillPlan(
            for: date ?? now,
            existingWall: existing.map { (time: $0.0, type: $0.1) },
            configs: schedule, now: now)
    }

    func testMidDayPreselectsDueSlotsAndDisablesTheExit() {
        let plans = plan(now: at(14, 0))
        XCTAssertEqual(plans.map(\.preselect), [true, true, true, false])
        XCTAssertEqual(plans.map(\.canSubmit), [true, true, true, false])
    }

    func testEndOfDayPreselectsOnlyBookends() {
        let plans = plan(now: at(17, 0))
        XCTAssertEqual(plans.map(\.preselect), [true, false, false, true])
        XCTAssertEqual(plans.map(\.canSubmit), [true, true, true, true]) // lunch stays selectable
    }

    func testPastDayPreselectsOnlyBookends() {
        let plans = plan(now: at(9, 0, day: 20), date: at(9, 0, day: 19))
        XCTAssertEqual(plans.map(\.preselect), [true, false, false, true])
    }

    func testExitOnlyBecomesAvailableAfterItsTime() {
        let existing = [("07:30", "in"), ("12:00", "out"), ("13:00", "in")]
        XCTAssertFalse(plan(existing, now: at(16, 29)).last!.canSubmit)
        XCTAssertTrue(plan(existing, now: at(16, 31)).last!.canSubmit)
    }

    func testRecordedSlotsAreNotPreselected() {
        let plans = plan([("07:30", "in")], now: at(14, 0))
        XCTAssertEqual(plans.first?.status, .covered)
        XCTAssertEqual(plans.map(\.preselect), [false, true, true, false])
    }

    func testDueUsesLocalClockNotUTC() {
        // 10:16 local: 07:30 is due, 12:00 is not. (Regression: "now" used to be read as UTC.)
        let plans = plan(now: at(10, 16))
        XCTAssertEqual(plans.map(\.isDueNow), [true, false, false, false])
    }
}

final class PunchFormatTests: XCTestCase {
    func testWallTimeAppliesEmbeddedOffset() {
        // 2026-08-12 05:30 UTC with a +02:00 offset is 07:30 wall-clock.
        XCTAssertEqual(PunchFormat.wallTime("/Date(1786512600000+0200)/"), "07:30")
    }

    func testWallTimeWithoutOffset() {
        XCTAssertEqual(PunchFormat.wallTime("/Date(1786512600000)/"), "05:30")
    }

    func testWallTimeGarbage() {
        XCTAssertEqual(PunchFormat.wallTime("nonsense"), "?")
    }
}

@MainActor
final class SchedulerDecisionTests: XCTestCase {
    private func decide(
        _ type: String = "in", scheduled: Date = at(7, 30), now: Date = at(7, 33),
        nonWorking: Bool = false, last: (type: String, at: Date)? = nil
    ) -> AppModel.ScheduledPunchDecision {
        AppModel.decideScheduledPunch(type: type, scheduled: scheduled, now: now, isNonWorkingDay: nonWorking, lastPunch: last)
    }

    func testNormalWeekdayRuns() {
        XCTAssertEqual(decide(), .run)
    }

    func testWeekendIsSkipped() {
        // 2026-10-17 is a Saturday, 2026-10-18 a Sunday.
        XCTAssertEqual(decide(scheduled: at(7, 30, day: 17), now: at(7, 33, day: 17)), .skip("it's the weekend"))
        XCTAssertEqual(decide(scheduled: at(7, 30, day: 18), now: at(7, 33, day: 18)), .skip("it's the weekend"))
    }

    func testVacationOrHolidayIsSkipped() {
        XCTAssertEqual(decide(nonWorking: true), .skip("today is a vacation or holiday"))
    }

    func testStaleTimerAfterSleepIsSkipped() {
        // Slot 07:30, Mac wakes at 10:00.
        guard case .skip = decide(now: at(10, 0)) else { return XCTFail("expected skip") }
        // Jitter of up to 5 min is still fine.
        XCTAssertEqual(decide(now: at(7, 36)), .run)
    }

    func testDuplicateSameDirectionIsSkipped() {
        guard case .skip = decide(last: ("in", at(7, 29))) else { return XCTFail("expected skip") }
    }

    func testOppositeDirectionOrOldPunchDoesNotBlock() {
        XCTAssertEqual(decide(last: ("out", at(7, 31))), .run)
        XCTAssertEqual(decide("out", scheduled: at(12, 0), now: at(12, 2), last: ("out", at(8, 0))), .run)
    }
}
