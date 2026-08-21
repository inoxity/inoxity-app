import XCTest
@testable import Inoxity

final class StudyProgressTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // Case 1 & 2: fixed participant duration, regardless of rolling vs. fixed-cohort enrollment —
    // both computed identically, relative to the participant's own enrollment date.
    func testDayOfNOnEnrollmentDay() {
        let enrolled = date(2026, 1, 1)
        let progress = StudyProgress.current(startDate: enrolled, participantDurationDays: 14, calendar: utc, now: enrolled)
        XCTAssertEqual(progress, .dayOfN(day: 1, total: 14, progress: 1.0 / 14.0))
        XCTAssertEqual(progress.title, "Day 1 of 14")
    }

    func testDayOfNSixDaysIn() {
        let enrolled = date(2026, 1, 1)
        let now = date(2026, 1, 7) // 6 days later
        let progress = StudyProgress.current(startDate: enrolled, participantDurationDays: 14, calendar: utc, now: now)
        XCTAssertEqual(progress, .dayOfN(day: 7, total: 14, progress: 7.0 / 14.0))
        XCTAssertEqual(progress.title, "Day 7 of 14")
    }

    func testDayOfNClampsAtTotalOnceDurationElapses() {
        let enrolled = date(2026, 1, 1)
        let now = date(2026, 3, 1) // well past a 14-day duration
        let progress = StudyProgress.current(startDate: enrolled, participantDurationDays: 14, calendar: utc, now: now)
        XCTAssertEqual(progress, .dayOfN(day: 14, total: 14, progress: 1.0))
        XCTAssertEqual(progress.fractionComplete, 1.0)
    }

    // Case 3a: enrollment date known, no fixed duration configured.
    func testDayCountWithoutDuration() {
        let enrolled = date(2026, 1, 1)
        let now = date(2026, 1, 7)
        let progress = StudyProgress.current(startDate: enrolled, participantDurationDays: nil, calendar: utc, now: now)
        XCTAssertEqual(progress, .dayCount(day: 7))
        XCTAssertEqual(progress.title, "Day 7 in the study")
        XCTAssertNil(progress.fractionComplete)
    }

    // Case 3b: no enrollment date available at all.
    func testActiveWithoutEnrollmentDate() {
        let progress = StudyProgress.current(startDate: nil, participantDurationDays: 14, calendar: utc, now: date(2026, 1, 7))
        XCTAssertEqual(progress, .active)
        XCTAssertEqual(progress.title, "Study active")
        XCTAssertNil(progress.fractionComplete)
    }

    // Case 4: a global calendar start/end date existing on the study is out of scope for this
    // function entirely — it only ever reads enrollmentDate/participantDurationDays — so a study
    // with no participantDurationDays configured always falls through to Case 3 behavior.
    func testFallsThroughToDayCountWhenNoDurationConfigured() {
        let enrolled = date(2026, 1, 1)
        let progress = StudyProgress.current(startDate: enrolled, participantDurationDays: nil, calendar: utc, now: date(2026, 1, 2))
        if case .dayCount = progress {} else { XCTFail("Expected .dayCount, got \(progress)") }
    }

    func testZeroOrNegativeDurationTreatedAsUnconfigured() {
        let enrolled = date(2026, 1, 1)
        let progress = StudyProgress.current(startDate: enrolled, participantDurationDays: 0, calendar: utc, now: date(2026, 1, 2))
        if case .dayCount = progress {} else { XCTFail("Expected .dayCount for a non-positive duration, got \(progress)") }
    }

    // isPastParticipantDuration — used to trigger StudyCompletionView. Deliberately not derived
    // from current(...)'s clamped day, since that can never itself signal having gone past `total`.
    func testIsPastParticipantDurationFalseOnLastDay() {
        let enrolled = date(2026, 1, 1)
        let now = date(2026, 1, 14) // day 14 of a 14-day study — still within the duration
        XCTAssertFalse(StudyProgress.isPastParticipantDuration(startDate: enrolled, participantDurationDays: 14, calendar: utc, now: now))
    }

    func testIsPastParticipantDurationTrueOneDayAfter() {
        let enrolled = date(2026, 1, 1)
        let now = date(2026, 1, 15) // day 15 — one day past a 14-day study
        XCTAssertTrue(StudyProgress.isPastParticipantDuration(startDate: enrolled, participantDurationDays: 14, calendar: utc, now: now))
    }

    func testIsPastParticipantDurationFalseForOpenEndedStudy() {
        let enrolled = date(2026, 1, 1)
        let now = date(2027, 1, 1) // a year later — still never "complete" with no fixed duration
        XCTAssertFalse(StudyProgress.isPastParticipantDuration(startDate: enrolled, participantDurationDays: nil, calendar: utc, now: now))
    }

    func testIsPastParticipantDurationFalseWithoutEnrollmentDate() {
        XCTAssertFalse(StudyProgress.isPastParticipantDuration(startDate: nil, participantDurationDays: 14, calendar: utc, now: date(2026, 1, 20)))
    }

    func testIsPastParticipantDurationFalseForZeroOrNegativeDuration() {
        let enrolled = date(2026, 1, 1)
        XCTAssertFalse(StudyProgress.isPastParticipantDuration(startDate: enrolled, participantDurationDays: 0, calendar: utc, now: date(2026, 6, 1)))
    }

    // MARK: - .notYetStarted (a resolved start date, e.g. .fixed/.participantSelected, in the future)

    func testNotYetStartedWhenNowPrecedesStartDate() {
        let startsOn = date(2026, 6, 1)
        let progress = StudyProgress.current(startDate: startsOn, participantDurationDays: 14, calendar: utc, now: date(2026, 5, 20))
        XCTAssertEqual(progress, .notYetStarted(startsOn: startsOn))
        XCTAssertEqual(progress.title, "Study hasn't started yet")
        XCTAssertNil(progress.fractionComplete)
        XCTAssertNil(progress.dayAndTotal)
    }

    func testTransitionsToDayOneExactlyOnTheStartDate() {
        let startsOn = date(2026, 6, 1)
        let progress = StudyProgress.current(startDate: startsOn, participantDurationDays: 14, calendar: utc, now: startsOn)
        XCTAssertEqual(progress, .dayOfN(day: 1, total: 14, progress: 1.0 / 14.0))
    }

    func testNotYetStartedAlsoAppliesWithNoFixedDuration() {
        let startsOn = date(2026, 6, 1)
        let progress = StudyProgress.current(startDate: startsOn, participantDurationDays: nil, calendar: utc, now: date(2026, 5, 20))
        XCTAssertEqual(progress, .notYetStarted(startsOn: startsOn))
    }

    func testIsPastParticipantDurationFalseWhileNotYetStarted() {
        // A future start date must never register as "past duration" even though the naive
        // days-elapsed math would be negative.
        let startsOn = date(2026, 6, 1)
        XCTAssertFalse(StudyProgress.isPastParticipantDuration(startDate: startsOn, participantDurationDays: 14, calendar: utc, now: date(2026, 5, 20)))
    }
}
