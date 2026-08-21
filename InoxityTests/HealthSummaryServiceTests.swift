import XCTest
@testable import Inoxity

@MainActor
final class HealthSummaryServiceTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!

    func testOneOverlapAdjacentAwakeInBedAndZeroDurationAggregation() throws {
        let calendar = makeCalendar(), interval = DateInterval(start: date(2026, 7, 1), end: date(2026, 7, 3))
        let samples: [HealthSleepSample] = [
            .init(startDate: date(2026,7,1,22), endDate: date(2026,7,2,6), state: .asleep),
            .init(startDate: date(2026,7,1,23), endDate: date(2026,7,2,2), state: .asleep),
            .init(startDate: date(2026,7,2,6), endDate: date(2026,7,2,7), state: .asleep),
            .init(startDate: date(2026,7,2,2), endDate: date(2026,7,2,3), state: .awake),
            .init(startDate: date(2026,7,1,21), endDate: date(2026,7,1,22), state: .inBed),
            .init(startDate: date(2026,7,2,8), endDate: date(2026,7,2,8), state: .asleep)
        ]
        let summary = HealthSummaryService.sleepSummary(samples: samples, interval: interval, now: interval.end, calendar: calendar)
        XCTAssertEqual(summary?.recordCount, 1)
        XCTAssertEqual(try XCTUnwrap(summary).latestDuration, 8 * 3600, accuracy: 0.1)
    }

    // Regression coverage for a code-review finding on the session-grouping fix above: sessions
    // must group from asleep fragments alone, not from raw awake/in-bed samples. A chain of
    // daytime in-bed/awake blips (resting, brief naps) spaced under sessionGapTolerance apart
    // eventually crosses into the next calendar day here — if those samples fed session grouping
    // (as an earlier version of this fix did), the whole *unrelated* prior night's sleep would
    // get pulled into that chain and misattributed to the day after its true wake day.
    func testDaytimeActivityChainDoesNotPullSleepIntoTheWrongDay() throws {
        let calendar = makeCalendar(), interval = DateInterval(start: date(2026, 7, 27), end: date(2026, 7, 30))
        let samples: [HealthSleepSample] = [
            .init(startDate: date(2026, 7, 27, 23), endDate: date(2026, 7, 28, 7), state: .asleep), // the actual night's sleep
            .init(startDate: date(2026, 7, 28, 10), endDate: date(2026, 7, 28, 10).addingTimeInterval(30 * 60), state: .inBed),
            .init(startDate: date(2026, 7, 28, 13), endDate: date(2026, 7, 28, 13).addingTimeInterval(15 * 60), state: .awake),
            .init(startDate: date(2026, 7, 28, 16).addingTimeInterval(30 * 60), endDate: date(2026, 7, 28, 16).addingTimeInterval(45 * 60), state: .inBed),
            .init(startDate: date(2026, 7, 28, 20), endDate: date(2026, 7, 28, 20).addingTimeInterval(15 * 60), state: .awake),
            // Crosses midnight into Jul 29 — under the earlier, buggier version of this fix this
            // chain (each link under the 4h gap tolerance) would have dragged the whole session's
            // end, and with it the night's sleep above, onto Jul 29.
            .init(startDate: date(2026, 7, 28, 23).addingTimeInterval(45 * 60), endDate: date(2026, 7, 29, 0).addingTimeInterval(15 * 60), state: .inBed),
        ]
        let summary = try XCTUnwrap(HealthSummaryService.sleepSummary(samples: samples, interval: interval, now: interval.end, calendar: calendar))
        XCTAssertEqual(summary.recordCount, 1)
        XCTAssertEqual(summary.latestDate, date(2026, 7, 28))
        XCTAssertEqual(summary.latestDuration, 8 * 3600, accuracy: 0.1)
    }

    func testInBedOnlyAndNoDataProduceNil() {
        let interval = DateInterval(start: date(2026,7,1), end: date(2026,7,2))
        XCTAssertNil(HealthSummaryService.sleepSummary(samples: [], interval: interval, now: interval.end, calendar: makeCalendar()))
        XCTAssertNil(HealthSummaryService.sleepSummary(samples: [.init(startDate: date(2026,7,1,22), endDate: date(2026,7,2,6), state: .inBed)], interval: interval, now: interval.end, calendar: makeCalendar()))
    }

    func testCrossMidnightClippingAndQueryBoundaries() throws {
        let interval = DateInterval(start: date(2026,7,2), end: date(2026,7,2,6))
        let value = HealthSleepSample(startDate: date(2026,7,1,22), endDate: date(2026,7,2,8), state: .asleep)
        let summary = HealthSummaryService.sleepSummary(samples: [value], interval: interval, now: interval.end, calendar: makeCalendar())
        XCTAssertEqual(try XCTUnwrap(summary).latestDuration, 6 * 3600, accuracy: 0.1)
        XCTAssertEqual(summary?.recordCount, 1)
    }

    func testDaylightSavingUsesActualElapsedTimeAndLocalSleepDay() throws {
        let start = date(2026,3,7,23), end = date(2026,3,8,7)
        let summary = HealthSummaryService.sleepSummary(samples: [.init(startDate: start, endDate: end, state: .asleep)],
            interval: .init(start: start, end: end), now: end, calendar: makeCalendar())
        XCTAssertEqual(try XCTUnwrap(summary).latestDuration, 7 * 3600, accuracy: 1)
        XCTAssertEqual(summary?.latestDate, makeCalendar().startOfDay(for: end))
    }

    func testIndependentMetricFailureAndPartialData() async throws {
        let query = MockHealthDataQueryService()
        query.sleepResult = .success([.init(startDate: date(2026,7,28,22), endDate: date(2026,7,29,6), state: .asleep)])
        query.quantityResults["restingHeartRate"] = .failure(HealthSummaryError.queryFailed)
        let now = date(2026,7,29,12)
        let service = HealthSummaryService(query: query, now: { now })
        let study = try fixture("SleepStudy")
        let snapshot = try await service.snapshot(configuration: study, participant: .init(studyID: study.identity.id))
        XCTAssertNotNil(snapshot.sleep); XCTAssertNil(snapshot.quantities["restingHeartRate"])
        XCTAssertEqual(snapshot.unavailableMetrics, ["restingHeartRate"])
    }

    func testDailyAndQuantitySummariesOnlyAppearWithData() async throws {
        let query = MockHealthDataQueryService(), study = try fixture("ActivityStudy")
        query.dailyResults["stepCount"] = .success([.init(day: date(2026,7,29), value: 4000)])
        let now = date(2026,7,29,12)
        let service = HealthSummaryService(query: query, now: { now })
        let value = try await service.snapshot(configuration: study, participant: .init(studyID: study.identity.id))
        XCTAssertEqual(value.dailyCumulative["stepCount"]?.today, 4000)
        XCTAssertNil(value.dailyCumulative["activeEnergyBurned"]); XCTAssertNil(value.dailyCumulative["appleExerciseTime"])
    }

    func testStructuredSummariesAreNotPartOfParticipantPersistence() throws {
        let encoded = try JSONEncoder().encode(ParticipantState(studyID: "sleep-cognition-v2"))
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("configuredMetrics"))
        XCTAssertFalse(json.contains("sevenDayAverage"))
        XCTAssertFalse(json.contains("thirtyDayAverage"))
    }

    // Workstream G: single-day snapshot for "See My Data"'s day-by-day navigation.
    func testDailySnapshotOnlyIncludesThatDaysSleep() async throws {
        let query = MockHealthDataQueryService()
        query.sleepResult = .success([
            .init(startDate: date(2026, 7, 26, 22), endDate: date(2026, 7, 27, 2), state: .asleep), // entirely 2 days before — excluded
            .init(startDate: date(2026, 7, 28, 1), endDate: date(2026, 7, 28, 5), state: .asleep),  // entirely within the target day
        ])
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let study = try fixture("SleepStudy")
        let snapshot = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                        day: date(2026, 7, 28, 12), timeZone: zone)
        XCTAssertEqual(snapshot.day, date(2026, 7, 28))
        // Only the 4-hour sample fully inside [Jul 28 00:00, Jul 29 00:00) counts; the other
        // sample is entirely outside that window.
        XCTAssertEqual(try XCTUnwrap(snapshot.sleepDuration), 4 * 3600, accuracy: 1)
    }

    func testDailySnapshotEmptyDayReturnsNilNotThrow() async throws {
        let query = MockHealthDataQueryService()
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let study = try fixture("SleepStudy")
        let snapshot = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                        day: date(2026, 7, 28), timeZone: zone)
        XCTAssertNil(snapshot.sleepDuration)
        XCTAssertFalse(snapshot.hasData)
    }

    func testDailySnapshotStepsIsASingleDayTotalNotAnAverage() async throws {
        let query = MockHealthDataQueryService(), study = try fixture("ActivityStudy")
        query.dailyResults["stepCount"] = .success([.init(day: date(2026, 7, 28), value: 5000)])
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let snapshot = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                        day: date(2026, 7, 28), timeZone: zone)
        XCTAssertEqual(snapshot.dailyTotals["stepCount"], 5000)
    }

    // Regression coverage for the bug where dailySnapshot's sleep number visibly disagreed with
    // the Health app: the old `sleepDuration` clipped samples to the plain single calendar day
    // BEFORE merging, splitting an overnight session at midnight and misattributing each half
    // instead of merging first and bucketing by wake day like `sleepSummary` (the correct 30-day
    // path) already did. See `HealthSummaryService.sleepQueryInterval`/`sleepDayBuckets`.
    func testDailySnapshotOvernightSessionAttributesFullDurationToWakeDay() async throws {
        let query = MockHealthDataQueryService()
        // Bedtime 11pm the evening before the target day, wakes 7am on the target day — exactly
        // the shape the old clip-before-merge bug mis-split at midnight.
        query.sleepResult = .success([
            .init(startDate: date(2026, 7, 27, 23), endDate: date(2026, 7, 28, 7), state: .asleep),
        ])
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let study = try fixture("SleepStudy")
        let snapshot = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                        day: date(2026, 7, 28), timeZone: zone)
        // Full 8 hours attributed to the wake day (Jul 28), not split/lost across the midnight boundary.
        XCTAssertEqual(try XCTUnwrap(snapshot.sleepDuration), 8 * 3600, accuracy: 1)
    }

    func testDailySnapshotQueriesAPaddedLookbackWindowForSleep() async throws {
        let query = MockHealthDataQueryService()
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let study = try fixture("SleepStudy")
        _ = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                             day: date(2026, 7, 28), timeZone: zone)
        let queried = try XCTUnwrap(query.sleepQueryIntervals.first)
        // Padded 24h before the day's own start (Jul 27 00:00), not the plain day boundary
        // (Jul 28 00:00) — guards against silently regressing back to the unpadded single-day query.
        XCTAssertEqual(queried.start, date(2026, 7, 27))
        XCTAssertEqual(queried.end, date(2026, 7, 29))
    }

    func testDailySnapshotExcludesSessionsStartingMoreThanADayBefore() async throws {
        let query = MockHealthDataQueryService()
        // Ends well before the padded lookback window even starts (Jul 27 00:00) — must not leak
        // into the target day's total.
        query.sleepResult = .success([
            .init(startDate: date(2026, 7, 25, 22), endDate: date(2026, 7, 26, 6), state: .asleep),
        ])
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let study = try fixture("SleepStudy")
        let snapshot = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                        day: date(2026, 7, 28), timeZone: zone)
        XCTAssertNil(snapshot.sleepDuration)
    }

    func testDailySnapshotDoesNotDoubleCountAcrossAdjacentDays() async throws {
        let query = MockHealthDataQueryService()
        query.sleepResult = .success([
            .init(startDate: date(2026, 7, 27, 23), endDate: date(2026, 7, 28, 7), state: .asleep),
        ])
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let study = try fixture("SleepStudy")
        let wakeDay = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                       day: date(2026, 7, 28), timeZone: zone)
        let priorDay = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                        day: date(2026, 7, 27), timeZone: zone)
        XCTAssertEqual(try XCTUnwrap(wakeDay.sleepDuration), 8 * 3600, accuracy: 1)
        XCTAssertNil(priorDay.sleepDuration) // the whole session belongs to the wake day, never the bedtime day
    }

    // Regression coverage for a second, subtler misattribution the wake-day bucketing fix above
    // didn't catch: a brief pre-midnight awakening (checking the time, rolling over) splits the
    // asleep signal into two merged fragments — one ending before midnight, one after. Bucketing
    // each fragment independently by its OWN end day (rather than the whole night's session)
    // stranded the pre-midnight fragment on the previous calendar day instead of the wake day —
    // undercounting the true wake day and, symmetrically, overcounting the day before by exactly
    // the stranded amount. See `sleepDayBuckets`'s session-grouping doc comment.
    func testDailySnapshotGroupsAPreMidnightAwakeningIntoTheSameNightsWakeDay() async throws {
        let query = MockHealthDataQueryService()
        query.sleepResult = .success([
            .init(startDate: date(2026, 7, 27, 21).addingTimeInterval(30 * 60), // 9:30pm
                  endDate: date(2026, 7, 27, 23).addingTimeInterval(30 * 60), state: .asleep), // 11:30pm
            .init(startDate: date(2026, 7, 27, 23).addingTimeInterval(30 * 60), // 11:30pm
                  endDate: date(2026, 7, 27, 23).addingTimeInterval(45 * 60), state: .awake), // 11:45pm
            .init(startDate: date(2026, 7, 27, 23).addingTimeInterval(45 * 60), // 11:45pm
                  endDate: date(2026, 7, 28, 7), state: .asleep), // 7am the next morning
        ])
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let study = try fixture("SleepStudy")
        let wakeDay = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                        day: date(2026, 7, 28), timeZone: zone)
        let priorDay = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                         day: date(2026, 7, 27), timeZone: zone)
        // 2h (before the awakening) + 7h15m (after) = 9h15m, all on the wake day — not split across
        // midnight, and not lost to the day before.
        XCTAssertEqual(try XCTUnwrap(wakeDay.sleepDuration), 9 * 3600 + 15 * 60, accuracy: 1)
        XCTAssertNil(priorDay.sleepDuration)
    }

    func testDailySnapshotIndependentMetricFailureIsReportedNotThrown() async throws {
        let query = MockHealthDataQueryService()
        query.quantityResults["restingHeartRate"] = .failure(HealthSummaryError.queryFailed)
        let fixedNow = date(2026, 7, 29, 12)
        let service = HealthSummaryService(query: query, now: { fixedNow })
        let study = try fixture("SleepStudy")
        let snapshot = try await service.dailySnapshot(configuration: study, participant: .init(studyID: study.identity.id),
                                                        day: date(2026, 7, 28), timeZone: zone)
        XCTAssertEqual(snapshot.unavailableMetrics, ["restingHeartRate"])
    }

    private func makeCalendar() -> Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { makeCalendar().date(from: .init(year: y, month: m, day: d, hour: h))! }
    private func fixture(_ name: String) throws -> StudyConfiguration { let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")); return try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url)) }
}
