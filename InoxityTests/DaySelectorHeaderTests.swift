import XCTest
@testable import Inoxity

final class DaySelectorHeaderTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: .init(year: y, month: m, day: d))!
    }

    func testCanStepForwardWithinBoundsAndBlockedPastLatestDay() {
        let today = date(2026, 8, 15), enrollment = date(2026, 8, 1)
        XCTAssertTrue(DaySelectorHeader.canStep(from: today, delta: -1, earliestDay: enrollment, latestDay: today))
        XCTAssertFalse(DaySelectorHeader.canStep(from: today, delta: 1, earliestDay: enrollment, latestDay: today))
    }

    func testCanStepBackwardBlockedBeforeEarliestDay() {
        let enrollment = date(2026, 8, 1), today = date(2026, 8, 15)
        XCTAssertFalse(DaySelectorHeader.canStep(from: enrollment, delta: -1, earliestDay: enrollment, latestDay: today))
        XCTAssertTrue(DaySelectorHeader.canStep(from: enrollment, delta: 1, earliestDay: enrollment, latestDay: today))
    }

    func testSingleDayRangeCannotStepEitherDirection() {
        let onlyDay = date(2026, 8, 15)
        XCTAssertFalse(DaySelectorHeader.canStep(from: onlyDay, delta: -1, earliestDay: onlyDay, latestDay: onlyDay))
        XCTAssertFalse(DaySelectorHeader.canStep(from: onlyDay, delta: 1, earliestDay: onlyDay, latestDay: onlyDay))
    }

    /// Regression test for the live-view scenario the other cases above don't exercise: in
    /// SeeMyDataView, selectedDay/latestDay both start as `Date()` — real wall-clock time, not
    /// midnight — because navigating back a day and then forward again must land back on "today"
    /// even though every Date involved carries a non-midnight time-of-day component.
    func testCanStepForwardBackToTodayWithRealTimeOfDay() {
        let now = Calendar.current.date(bySettingHour: 15, minute: 15, second: 0, of: date(2026, 8, 15))!
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let enrollment = date(2026, 8, 1)
        XCTAssertTrue(DaySelectorHeader.canStep(from: yesterday, delta: 1, earliestDay: enrollment, latestDay: now))
    }
}
