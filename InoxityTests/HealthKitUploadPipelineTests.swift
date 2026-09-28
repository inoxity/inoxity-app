import XCTest
@testable import Inoxity

final class HealthKitUploadPipelineTests: XCTestCase {
    private let sampleID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    // rawQuantity(_:_:) below always builds a "stepCount" sample — read its valid unit off the
    // registry rather than hardcoding it a second time, so a future canonicalUploadUnit change
    // can't silently make these tests stale again.
    private let validUnit = HealthKitCanonicalUnit.forIdentifier("stepCount")!
    func testDeterministicIdentityIsStableAndStudyMetricScoped() {
        let a = HealthKitSampleIdentityFactory.id(studyID: "sleep", identifier: "stepCount", sampleUUID: sampleID)
        XCTAssertEqual(a, HealthKitSampleIdentityFactory.id(studyID: "sleep", identifier: "stepCount", sampleUUID: sampleID))
        XCTAssertNotEqual(a, HealthKitSampleIdentityFactory.id(studyID: "activity", identifier: "stepCount", sampleUUID: sampleID))
        XCTAssertNotEqual(a, HealthKitSampleIdentityFactory.id(studyID: "sleep", identifier: "heartRate", sampleUUID: sampleID))
        XCTAssertFalse(a.localizedCaseInsensitiveContains("sona"))
    }
    // canonicalUploadUnit doubles as the human-readable label shown in local summaries (see its
    // doc comment on HealthKitTypeMetadata) — stepCount/heart-rate-family/respiratoryRate use the
    // friendlier "steps"/"beats/min"/"breaths/min" rather than raw HKUnit strings like "count".
    func testCanonicalUnitsCoverAllQuantityIdentifiers() {
        XCTAssertEqual(HealthKitCanonicalUnit.forIdentifier("stepCount"), "steps")
        XCTAssertEqual(HealthKitCanonicalUnit.forIdentifier("restingHeartRate"), "beats/min")
        XCTAssertEqual(HealthKitCanonicalUnit.forIdentifier("heartRate"), "beats/min")
        XCTAssertEqual(HealthKitCanonicalUnit.forIdentifier("heartRateVariabilitySDNN"), "ms")
        XCTAssertEqual(HealthKitCanonicalUnit.forIdentifier("activeEnergyBurned"), "kcal")
        XCTAssertEqual(HealthKitCanonicalUnit.forIdentifier("appleExerciseTime"), "min")
        XCTAssertEqual(HealthKitCanonicalUnit.forIdentifier("respiratoryRate"), "breaths/min")
        XCTAssertEqual(HealthKitCanonicalUnit.forIdentifier("timeInDaylight"), "min")
    }
    func testQuantityNormalizationAndInvalidValues() throws {
        let raw = rawQuantity(value: 12, unit: validUnit)
        let value = try HealthKitSampleNormalizer.normalize(raw, participant: participant(), now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(value.quantityValue, 12); XCTAssertEqual(value.quantityUnit, validUnit)
        XCTAssertThrowsError(try HealthKitSampleNormalizer.normalize(rawQuantity(value: .nan, unit: validUnit), participant: participant(), now: Date()))
        XCTAssertThrowsError(try HealthKitSampleNormalizer.normalize(rawQuantity(value: .infinity, unit: validUnit), participant: participant(), now: Date()))
        XCTAssertThrowsError(try HealthKitSampleNormalizer.normalize(rawQuantity(value: -1, unit: validUnit), participant: participant(), now: Date()))
        XCTAssertThrowsError(try HealthKitSampleNormalizer.normalize(rawQuantity(value: 1, unit: "ms"), participant: participant(), now: Date())) // deliberately wrong unit for stepCount
    }
    func testSleepAndWorkoutNormalization() throws {
        let sleep = HealthKitRawSample(uuid: sampleID, identifier: "sleepAnalysis", kind: .category,
            start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), timeZoneIdentifier: "America/Los_Angeles",
            quantityValue: nil, canonicalUnit: nil, categoryValue: 3, workoutActivityType: nil, workoutDurationSeconds: nil)
        XCTAssertEqual(try HealthKitSampleNormalizer.normalize(sleep, participant: participant(), now: Date()).categoryValue, 3)
        let workout = HealthKitRawSample(uuid: sampleID, identifier: "workout", kind: .workout,
            start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 61), timeZoneIdentifier: "America/Los_Angeles",
            quantityValue: nil, canonicalUnit: nil, categoryValue: nil, workoutActivityType: 37, workoutDurationSeconds: 60)
        XCTAssertEqual(try HealthKitSampleNormalizer.normalize(workout, participant: participant(), now: Date()).workoutDurationSeconds, 60)
    }
    func testEndBeforeStartRejected() {
        let raw = HealthKitRawSample(uuid: sampleID, identifier: "stepCount", kind: .quantity,
            start: Date(timeIntervalSince1970: 2), end: Date(timeIntervalSince1970: 1), timeZoneIdentifier: "America/Los_Angeles",
            quantityValue: 1, canonicalUnit: "count", categoryValue: nil, workoutActivityType: nil, workoutDurationSeconds: nil)
        XCTAssertThrowsError(try HealthKitSampleNormalizer.normalize(raw, participant: participant(), now: Date()))
    }
    func testTimeZoneIdentifierPassesThroughNormalizationUnchanged() throws {
        let raw = rawQuantity(value: 12, unit: validUnit)
        let value = try HealthKitSampleNormalizer.normalize(raw, participant: participant(), now: Date())
        XCTAssertEqual(value.sampleTimeZoneIdentifier, "America/Los_Angeles")
    }
    func testQueueRoundTripIdempotencyIsolationAndReset() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "queue")
        let one = try HealthKitSampleNormalizer.normalize(rawQuantity(value: 1, unit: validUnit), participant: participant(studyID: "one"), now: Date())
        let two = try HealthKitSampleNormalizer.normalize(rawQuantity(value: 2, unit: validUnit), participant: participant(studyID: "two"), now: Date())
        try await queue.enqueue([one, one, two])
        let queueOne = await queue.records(studyID: "one"), queueTwo = await queue.records(studyID: "two")
        XCTAssertEqual(queueOne.count, 1); XCTAssertEqual(queueTwo.count, 1)
        let restored = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "queue")
        let restoredOne = await restored.records(studyID: "one"); XCTAssertEqual(restoredOne, [one])
        try await restored.reset(studyID: "one")
        let resetOne = await restored.records(studyID: "one"), retainedTwo = await restored.records(studyID: "two")
        XCTAssertTrue(resetOne.isEmpty); XCTAssertEqual(retainedTwo.count, 1)
    }
    func testQueueRecoversStaleSyncAndCorruptData() async throws {
        let defaults = temporaryDefaults(); let key = "queue"
        let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: key)
        var value = try HealthKitSampleNormalizer.normalize(rawQuantity(value: 1, unit: validUnit), participant: participant(), now: Date())
        value.syncStatus = .syncing; try await queue.enqueue([value])
        let restored = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: key)
        let recovered = await restored.records(studyID: "study"); XCTAssertEqual(recovered.first?.syncStatus, .pending)
        defaults.set(Data("corrupt".utf8), forKey: key)
        let corruptRecords = await UserDefaultsHealthKitUploadQueue(defaults: defaults, key: key).allRecords(); XCTAssertTrue(corruptRecords.isEmpty)
    }
    func testCursorRoundTripIsolationCandidateAndReset() async throws {
        let defaults = temporaryDefaults(); let store = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "cursor")
        let key = cursorKey(studyID: "one"); let value = HealthKitSyncCursor(key: key, committedAnchor: Data([1]),
            candidateAnchor: Data([2]), candidateRequiredSampleIDs: ["a"], lastQueryAttempt: Date(),
            lastSuccessfulPromotion: nil, status: .awaitingAcknowledgments)
        try await store.save(value); let restored = await store.cursor(for: key); XCTAssertEqual(restored, value)
        try await store.save(.init(key: cursorKey(studyID: "two"), committedAnchor: nil, candidateAnchor: nil,
            candidateRequiredSampleIDs: [], lastQueryAttempt: nil, lastSuccessfulPromotion: nil, status: .ready))
        try await store.reset(studyID: "one")
        let removed = await store.cursor(for: key), retained = await store.cursors(studyID: "two")
        XCTAssertNil(removed); XCTAssertEqual(retained.count, 1)
    }
    func testPartialAcknowledgmentBlocksCursorPromotionAndFullAcknowledgmentPromotes() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c")
        let query = MockRawQuery(samples: [rawQuantity(value: 1, unit: validUnit)], deleted: 2)
        let partial = MockHealthRepository(acknowledge: false)
        let coordinator = HealthKitUploadCoordinator(query: query, queue: queue, cursors: cursors, now: { Date(timeIntervalSince1970: 100) })
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: partial)
        let candidate = await cursors.cursor(for: cursorKey()); XCTAssertNotNil(candidate?.candidateAnchor)
        let full = MockHealthRepository(acknowledge: true)
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: full)
        let cursor = await cursors.cursor(for: cursorKey())
        XCTAssertNil(cursor?.candidateAnchor); XCTAssertNotNil(cursor?.committedAnchor)
        let submissionCount = await full.submissions(); XCTAssertEqual(submissionCount, 1)
    }
    func testDeletedObjectsProduceNoUploadAndAnchorStillPromotes() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q2")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c2")
        let coordinator = HealthKitUploadCoordinator(query: MockRawQuery(samples: [], deleted: 3), queue: queue, cursors: cursors)
        let repo = MockHealthRepository(acknowledge: true)
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: repo)
        let records = await queue.records(studyID: "study"), cursor = await cursors.cursor(for: cursorKey()), submissions = await repo.submissions()
        XCTAssertTrue(records.isEmpty); XCTAssertNotNil(cursor?.committedAnchor); XCTAssertEqual(submissions, 0)
    }
    func testSynchronizeDrainsAllAvailableQueryPages() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q-pages")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c-pages")
        let query = PagedRawQuery(pages: [
            .init(samples: [], nextAnchor: Data([1]), hasMore: true, ignoredDeletionCount: 1),
            .init(samples: [], nextAnchor: Data([2]), hasMore: false, ignoredDeletionCount: 1)
        ])
        let coordinator = HealthKitUploadCoordinator(query: query, queue: queue, cursors: cursors)
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: MockHealthRepository(acknowledge: true))
        let cursor = await cursors.cursor(for: cursorKey())
        let callCount = await query.callCount(identifier: "stepCount")
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(cursor?.committedAnchor, Data([2]))
        XCTAssertNil(cursor?.candidateAnchor)
    }
    func testRejectedSampleIsSetAsideWithoutBlockingItsBatchOrCursor() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q-reject")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c-reject")
        let uuids = (1...5).map { UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000\($0)")! }
        let bad = HealthKitSampleIdentityFactory.id(studyID: "study", identifier: "stepCount", sampleUUID: uuids[2])
        let repo = ScriptedHealthRepository { batch in
            if batch.contains(where: { $0.clientSampleID == bad }) { throw HealthKitUploadError.invalidSample }
        }
        let coordinator = HealthKitUploadCoordinator(query: IdentifierScopedQuery(samples: uuids.map { raw(uuid: $0, identifier: "stepCount") }),
                                                     queue: queue, cursors: cursors)
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: repo)
        let records = await queue.records(studyID: "study"), diagnostics = await queue.diagnostics(studyID: "study")
        XCTAssertEqual(records.map(\.clientSampleID), [bad], "acknowledged samples are pruned; only the rejected one stays")
        XCTAssertEqual(records.first?.syncStatus, .attentionRequired); XCTAssertEqual(records.first?.setAsideAfterRejection, true)
        XCTAssertEqual(diagnostics.acknowledged, 4); XCTAssertEqual(diagnostics.attentionRequired, 1)
        let cursor = await cursors.cursor(for: cursorKey())
        XCTAssertNotNil(cursor?.committedAnchor); XCTAssertNil(cursor?.candidateAnchor)
        // Set aside for good: a later pass doesn't re-send it.
        let before = await repo.batchCount()
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: repo)
        let after = await repo.batchCount(); XCTAssertEqual(after, before)
    }
    func testRetryableFailureInOneMetricDoesNotBlockAnother() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q-metrics")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c-metrics")
        let repo = ScriptedHealthRepository { batch in
            if batch.contains(where: { $0.healthKitIdentifier == "activeEnergyBurned" }) { throw HealthKitUploadError.unavailable }
        }
        let samples = [raw(uuid: UUID(), identifier: "activeEnergyBurned", start: 1), raw(uuid: UUID(), identifier: "stepCount", start: 2)]
        let coordinator = HealthKitUploadCoordinator(query: IdentifierScopedQuery(samples: samples), queue: queue, cursors: cursors)
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: repo)
        let steps = await cursors.cursor(for: cursorKey(identifier: "stepCount"))
        let energy = await cursors.cursor(for: cursorKey(identifier: "activeEnergyBurned"))
        XCTAssertNotNil(steps?.committedAnchor); XCTAssertNil(steps?.candidateAnchor)
        XCTAssertNil(energy?.committedAnchor); XCTAssertNotNil(energy?.candidateAnchor)
        let pending = await queue.records(studyID: "study")
        XCTAssertEqual(pending.map(\.healthKitIdentifier), ["activeEnergyBurned"]); XCTAssertEqual(pending.first?.syncStatus, .retryableFailure)
    }
    func testSystemicFailureLeavesRecordsForRetryAndCursorUnpromoted() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q-systemic")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c-systemic")
        let repo = ScriptedHealthRepository { _ in throw BackendError.ownershipDenied }
        let coordinator = HealthKitUploadCoordinator(query: IdentifierScopedQuery(samples: [raw(uuid: UUID(), identifier: "stepCount")]),
                                                     queue: queue, cursors: cursors)
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: repo)
        let records = await queue.records(studyID: "study"), cursor = await cursors.cursor(for: cursorKey())
        XCTAssertEqual(records.map(\.syncStatus), [.pending]); XCTAssertEqual(records.first?.setAsideAfterRejection, nil)
        XCTAssertNil(cursor?.committedAnchor); XCTAssertNotNil(cursor?.candidateAnchor)
    }
    func testLegacyAttentionRequiredRecordGetsAnotherAttempt() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q-legacy")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c-legacy")
        // What a batch-wide non-retryable failure left behind before setAsideAfterRejection existed.
        var stuck = try HealthKitSampleNormalizer.normalize(raw(uuid: UUID(), identifier: "stepCount"), participant: participant(), now: Date())
        stuck.syncStatus = .attentionRequired; stuck.retryCount = 7
        try await queue.enqueue([stuck])
        let repo = ScriptedHealthRepository { _ in }
        let coordinator = HealthKitUploadCoordinator(query: IdentifierScopedQuery(samples: []), queue: queue, cursors: cursors)
        _ = await coordinator.synchronize(state: participant(), configuration: try await configuration(), repository: repo)
        let diagnostics = await queue.diagnostics(studyID: "study")
        XCTAssertEqual(diagnostics.acknowledged, 1); XCTAssertEqual(diagnostics.attentionRequired, 0)
    }
    func testPruneKeepsCursorRequiredIDsAndDiagnosticsSurviveReload() async throws {
        let defaults = temporaryDefaults(); let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q-prune")
        var records = try [UUID(), UUID(), UUID()].map { try HealthKitSampleNormalizer.normalize(raw(uuid: $0, identifier: "stepCount"), participant: participant(), now: Date()) }
        let acknowledgedAt = Date(timeIntervalSince1970: 500)
        for index in 0..<2 { records[index].syncStatus = .acknowledged; records[index].acknowledgedAt = acknowledgedAt }
        try await queue.enqueue(records)
        try await queue.pruneAcknowledged(studyID: "study", keeping: [records[1].clientSampleID])
        let remaining = await queue.records(studyID: "study")
        XCTAssertEqual(Set(remaining.map(\.clientSampleID)), [records[1].clientSampleID, records[2].clientSampleID])
        let reloaded = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q-prune")
        let diagnostics = await reloaded.diagnostics(studyID: "study")
        XCTAssertEqual(diagnostics.acknowledged, 2); XCTAssertEqual(diagnostics.pending, 1)
        XCTAssertEqual(diagnostics.lastSuccessfulUpload, acknowledgedAt)
        try await reloaded.reset(studyID: "study")
        let cleared = await reloaded.diagnostics(studyID: "study"); XCTAssertEqual(cleared, .empty)
    }
    func testBackendSampleRejectionsMapToNonRetryableErrors() {
        struct ServerError: Error, CustomStringConvertible { let description: String }
        XCTAssertEqual(SupabaseBackendErrorMapper.healthKitSampleRejection(ServerError(description: "PostgrestError(message: \"invalid quantity sample\")")), .invalidSample)
        XCTAssertEqual(SupabaseBackendErrorMapper.healthKitSampleRejection(ServerError(description: "conflicting duplicate identity")), .conflictingDuplicate)
        XCTAssertNil(SupabaseBackendErrorMapper.healthKitSampleRejection(ServerError(description: "relation \"public.step_count_samples\" does not exist")))
        XCTAssertNil(SupabaseBackendErrorMapper.healthKitSampleRejection(URLError(.notConnectedToInternet)))
    }
    func testPolicyIsCentralizedAndBounded() {
        XCTAssertEqual(HealthKitUploadPolicy.phase3D.initialHistoryDays, 30)
        XCTAssertEqual(HealthKitUploadPolicy.phase3D.maximumQueryPageSize, 250)
        XCTAssertEqual(HealthKitUploadPolicy.phase3D.maximumUploadBatchSize, 250)
        XCTAssertEqual(HealthKitUploadPolicy.phase3D.overlapMinutes, 5)
    }

    // Regression coverage for the bug where `collectionStart` took the max() of the backfill
    // window and `enrollmentDate`, making pre-enrollment historical data structurally
    // unreachable regardless of how many backfill days were configured.
    func testLegacySchemaVersionKeepsFixed30DayWindowUnclampedByEnrollment() async throws {
        let defaults = temporaryDefaults()
        let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q3")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c3")
        let capture = CapturingQuery()
        let now = Date(timeIntervalSince1970: 1_800_000_000) // far after ActivityStudy's 2025-01-01 startDate
        let coordinator = HealthKitUploadCoordinator(query: capture, queue: queue, cursors: cursors, now: { now })
        // schemaVersion 5 config, enrolled "just now" — pre-fix this would have clamped the
        // start to `enrollmentDate` (== now), making the 30-day window meaningless.
        let recentlyEnrolled = participant(enrollmentDate: now)
        _ = await coordinator.synchronize(state: recentlyEnrolled, configuration: try await configuration(), repository: MockHealthRepository(acknowledge: true))
        let lastStart = await capture.lastStart
        let start = try XCTUnwrap(lastStart)
        let expected = Calendar(identifier: .gregorian).date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(start.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testSchemaVersion7ConfiguredBackfillDaysUnclampedByEnrollment() async throws {
        let defaults = temporaryDefaults()
        let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q4")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c4")
        let capture = CapturingQuery()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = HealthKitUploadCoordinator(query: capture, queue: queue, cursors: cursors, now: { now })
        let config = try await configuration(schemaVersion: 7, backfillDays: 7)
        let recentlyEnrolled = participant(enrollmentDate: now, enrolledConfigurationSchemaVersion: 7)
        _ = await coordinator.synchronize(state: recentlyEnrolled, configuration: config, repository: MockHealthRepository(acknowledge: true))
        let lastStart = await capture.lastStart
        let start = try XCTUnwrap(lastStart)
        let expected = Calendar(identifier: .gregorian).date(byAdding: .day, value: -7, to: now)!
        XCTAssertEqual(start.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testSchemaVersion7NilBackfillDaysMeansFullHistoryNotClampedByEnrollment() async throws {
        let defaults = temporaryDefaults()
        let queue = UserDefaultsHealthKitUploadQueue(defaults: defaults, key: "q5")
        let cursors = UserDefaultsHealthKitSyncCursorStore(defaults: defaults, key: "c5")
        let capture = CapturingQuery()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = HealthKitUploadCoordinator(query: capture, queue: queue, cursors: cursors, now: { now })
        let config = try await configuration(schemaVersion: 7, backfillDays: nil) // full history
        let recentlyEnrolled = participant(enrollmentDate: now, enrolledConfigurationSchemaVersion: 7)
        _ = await coordinator.synchronize(state: recentlyEnrolled, configuration: config, repository: MockHealthRepository(acknowledge: true))
        let lastStart = await capture.lastStart
        let start = try XCTUnwrap(lastStart)
        // Ideally this would be bounded by ActivityStudy.json's schedule.startDate
        // (2025-01-01), but `Self.parse` can't parse plain "yyyy-MM-dd" strings today (a
        // separate, pre-existing, deliberately-not-fixed-here bug — see `Self.parse`'s
        // comment), so it falls back to the 10-year floor. The important assertion is what
        // this test is actually named for: it is NOT clamped to `enrollmentDate` (== now).
        let expected = Calendar(identifier: .gregorian).date(byAdding: .year, value: -10, to: now)!
        XCTAssertEqual(start.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
        XCTAssertLessThan(start, now)
    }

    private func rawQuantity(value: Double, unit: String) -> HealthKitRawSample { .init(uuid: sampleID, identifier: "stepCount", kind: .quantity,
        start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), timeZoneIdentifier: "America/Los_Angeles",
        quantityValue: value, canonicalUnit: unit, categoryValue: nil, workoutActivityType: nil, workoutDurationSeconds: nil) }
    private func participant(studyID: String = "study", enrollmentDate: Date = Date(timeIntervalSince1970: 0),
                             enrolledConfigurationSchemaVersion: Int = 5) -> ParticipantState {
        .init(studyID: studyID, enrollmentDate: enrollmentDate,
        participationStatus: .enrolled, healthKitRequestState: .requestCompleted, enrolledConfigurationSchemaVersion: enrolledConfigurationSchemaVersion,
        enrolledConfigurationRevision: 1, enrollmentSyncStatus: .registered, remoteEnrollmentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
        studyBackendID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"), studyBackendDescriptorCacheKey: "cache",
        studyBackendDescriptorRevision: 1, backendRoutingStatus: .registered)
    }
    private func cursorKey(studyID: String = "study", identifier: String = "stepCount") -> HealthKitSyncCursorKey { .init(stableStudyID: studyID,
        remoteEnrollmentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, studyBackendID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        descriptorCacheKey: "cache", healthKitIdentifier: identifier, configurationRevision: 1) }
    private func raw(uuid: UUID, identifier: String, start: TimeInterval = 1) -> HealthKitRawSample { .init(uuid: uuid, identifier: identifier, kind: .quantity,
        start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + 1), timeZoneIdentifier: "America/Los_Angeles",
        quantityValue: 1, canonicalUnit: HealthKitCanonicalUnit.forIdentifier(identifier), categoryValue: nil, workoutActivityType: nil, workoutDurationSeconds: nil) }
    private func configuration() async throws -> StudyConfiguration { try await BundledStudyConfigurationProvider(bundle: Bundle(for: Self.self)).configuration(for: "ACTIVITY02") }
    // Loads ActivityStudy.json (schedule.startDate == 2025-01-01) and overrides schemaVersion /
    // healthKit.backfillDays directly in the raw JSON before decoding, for testing Workstream
    // C's per-study backfill window without needing a dedicated fixture file per case.
    private func configuration(schemaVersion: Int, backfillDays: Int?) async throws -> StudyConfiguration {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ActivityStudy", withExtension: "json"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["schemaVersion"] = schemaVersion
        var healthKit = try XCTUnwrap(root["healthKit"] as? [String: Any])
        healthKit["backfillDays"] = backfillDays ?? NSNull()
        root["healthKit"] = healthKit
        return try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
    }
    private func temporaryDefaults() -> UserDefaults { let suite = "hk-upload-\(UUID())"; let value = UserDefaults(suiteName: suite)!; value.removePersistentDomain(forName: suite); return value }
}

private struct MockRawQuery: HealthKitSampleQuerying {
    let samples: [HealthKitRawSample]; let deleted: Int
    func query(identifier: String, start: Date, end: Date, anchor: Data?, limit: Int) async throws -> HealthKitSampleQueryPage {
        .init(samples: samples, nextAnchor: Data([9]), hasMore: false, ignoredDeletionCount: deleted)
    }
}
// Returns only the samples for the identifier being queried, once — the second query for an
// identifier (after its anchor advanced) comes back empty, like HealthKit's anchored query.
private actor IdentifierScopedQuery: HealthKitSampleQuerying {
    let samples: [HealthKitRawSample]
    init(samples: [HealthKitRawSample]) { self.samples = samples }
    func query(identifier: String, start: Date, end: Date, anchor: Data?, limit: Int) async throws -> HealthKitSampleQueryPage {
        .init(samples: anchor == nil ? samples.filter { $0.identifier == identifier } : [], nextAnchor: Data(identifier.utf8),
              hasMore: false, ignoredDeletionCount: 0)
    }
}
// Acknowledges every batch unless `reject` throws for it.
private actor ScriptedHealthRepository: HealthKitSampleUploadRepository {
    let reject: @Sendable ([HealthKitSampleUpload]) throws -> Void; private var count = 0
    init(reject: @escaping @Sendable ([HealthKitSampleUpload]) throws -> Void) { self.reject = reject }
    func submitHealthKitSamples(_ samples: [HealthKitSampleUpload]) async throws -> HealthKitBatchAcknowledgment {
        count += 1; try reject(samples)
        return .init(acknowledgments: samples.map { .init(clientSampleID: $0.clientSampleID, acknowledgmentID: UUID(), receivedAt: Date(), idempotentExisting: false) })
    }
    func batchCount() -> Int { count }
}
// Serves the same page sequence to each identifier independently — the fixture study configures
// several metrics, and each must drain its own pages.
private actor PagedRawQuery: HealthKitSampleQuerying {
    let pages: [HealthKitSampleQueryPage]
    private var indices: [String: Int] = [:]
    init(pages: [HealthKitSampleQueryPage]) { self.pages = pages }
    func query(identifier: String, start: Date, end: Date, anchor: Data?, limit: Int) async throws -> HealthKitSampleQueryPage {
        let index = indices[identifier, default: 0]; indices[identifier] = index + 1
        return pages[min(index, pages.count - 1)]
    }
    func callCount(identifier: String) -> Int { indices[identifier, default: 0] }
}
// Records the `start` date `HealthKitUploadCoordinator.collectionStart` actually computed and
// passed into the first query for the identifier under test — used by Workstream C's backfill
// window tests, which care about that value rather than any returned samples.
private actor CapturingQuery: HealthKitSampleQuerying {
    private(set) var lastStart: Date?
    func query(identifier: String, start: Date, end: Date, anchor: Data?, limit: Int) async throws -> HealthKitSampleQueryPage {
        lastStart = start
        return .init(samples: [], nextAnchor: Data([9]), hasMore: false, ignoredDeletionCount: 0)
    }
}
private actor MockHealthRepository: HealthKitSampleUploadRepository {
    let acknowledge: Bool; private var count = 0
    init(acknowledge: Bool) { self.acknowledge = acknowledge }
    func submitHealthKitSamples(_ samples: [HealthKitSampleUpload]) async throws -> HealthKitBatchAcknowledgment {
        count += 1
        return .init(acknowledgments: acknowledge ? samples.map { .init(clientSampleID: $0.clientSampleID, acknowledgmentID: UUID(), receivedAt: Date(), idempotentExisting: false) } : [])
    }
    func submissions() -> Int { count }
}
