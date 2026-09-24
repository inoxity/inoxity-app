import Foundation

struct HealthKitUploadRunResult: Equatable, Sendable { let attempted: Int; let succeeded: Int; let retryableFailures: Int; let nonRetryableFailures: Int }

protocol HealthKitUploadCoordinating: Sendable {
    func synchronize(state: ParticipantState, configuration: StudyConfiguration, repository: any HealthKitSampleUploadRepository) async -> HealthKitUploadRunResult
}

actor HealthKitUploadCoordinator: HealthKitUploadCoordinating {
    private let query: any HealthKitSampleQuerying
    private let queue: any HealthKitUploadQueuePersisting
    private let cursors: any HealthKitSyncCursorPersisting
    private let policy: HealthKitUploadPolicy
    private let now: @Sendable () -> Date
    init(query: any HealthKitSampleQuerying, queue: any HealthKitUploadQueuePersisting,
         cursors: any HealthKitSyncCursorPersisting, policy: HealthKitUploadPolicy = .phase3D,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.query = query; self.queue = queue; self.cursors = cursors; self.policy = policy; self.now = now
    }

    func synchronize(state: ParticipantState, configuration: StudyConfiguration,
                     repository: any HealthKitSampleUploadRepository) async -> HealthKitUploadRunResult {
        guard state.enrollmentSyncStatus == .registered, state.backendRoutingStatus == .registered,
              state.remoteEnrollmentID != nil, state.studyBackendID != nil else { return .init(attempted: 0, succeeded: 0, retryableFailures: 0, nonRetryableFailures: 1) }
        var counters = await uploadQueued(studyID: state.studyID, repository: repository)
        guard state.participationStatus == .enrolled, configuration.healthKit.enabled,
              state.healthKitRequestState == .requestCompleted else { return counters }
        for identifier in configuration.healthKit.identifiers.sorted() {
            do {
                guard let key = cursorKey(state: state, identifier: identifier) else { throw HealthKitUploadError.routingRequired }
                var cursor = await cursors.cursor(for: key) ?? .init(key: key, committedAnchor: nil, candidateAnchor: nil,
                    candidateRequiredSampleIDs: [], lastQueryAttempt: nil, lastSuccessfulPromotion: nil, status: .ready)
                if cursor.candidateAnchor != nil {
                    if await candidateAcknowledged(cursor) { try await promote(&cursor) }
                    else { continue }
                }
                let end = collectionEnd(configuration: configuration, now: now())
                let start = collectionStart(state: state, configuration: configuration, end: end)
                guard start < end else { continue }
                var hasMore = true
                while hasMore {
                    let page = try await query.query(identifier: identifier, start: start, end: end,
                                                     anchor: cursor.committedAnchor, limit: policy.maximumQueryPageSize)
                    let normalized = try page.samples.map { try HealthKitSampleNormalizer.normalize($0, participant: state, now: now()) }
                    try await queue.enqueue(normalized)
                    cursor.candidateAnchor = page.nextAnchor; cursor.candidateRequiredSampleIDs = normalized.map(\.clientSampleID)
                    cursor.lastQueryAttempt = now(); cursor.status = .awaitingAcknowledgments; try await cursors.save(cursor)
                    let uploaded = await uploadQueued(studyID: state.studyID, repository: repository)
                    counters = Self.add(counters, uploaded)
                    guard await candidateAcknowledged(cursor) else { break }
                    try await promote(&cursor)
                    hasMore = page.hasMore
                }
            } catch {
                counters = .init(attempted: counters.attempted + 1, succeeded: counters.succeeded,
                                 retryableFailures: counters.retryableFailures + (Self.retryable(error) ? 1 : 0),
                                 nonRetryableFailures: counters.nonRetryableFailures + (Self.retryable(error) ? 0 : 1))
            }
        }
        return counters
    }

    private func uploadQueued(studyID: String, repository: any HealthKitSampleUploadRepository) async -> HealthKitUploadRunResult {
        var records = await queue.records(studyID: studyID).filter { $0.syncStatus == .pending || $0.syncStatus == .retryableFailure }
        records.sort { ($0.sampleStart, $0.clientSampleID) < ($1.sampleStart, $1.clientSampleID) }
        var attempted = 0, succeeded = 0, retryableFailures = 0, nonRetryableFailures = 0
        for offset in stride(from: 0, to: records.count, by: policy.maximumUploadBatchSize) {
            let batch = Array(records[offset..<min(offset + policy.maximumUploadBatchSize, records.count)])
            attempted += 1
            do {
                let response = try await repository.submitHealthKitSamples(batch)
                let acknowledged = Dictionary(uniqueKeysWithValues: response.acknowledgments.map { ($0.clientSampleID, $0) })
                for var record in batch {
                    record.lastAttemptAt = now()
                    if let ack = acknowledged[record.clientSampleID] {
                        record.syncStatus = .acknowledged; record.acknowledgedAt = ack.receivedAt
                        record.remoteAcknowledgmentID = ack.acknowledgmentID; record.failureCategory = nil; succeeded += 1
                    } else { record.syncStatus = .retryableFailure; record.retryCount += 1; record.failureCategory = .unavailable; retryableFailures += 1 }
                    try await queue.update(record)
                }
            } catch {
                let retry = Self.retryable(error)
                for var record in batch {
                    record.lastAttemptAt = now(); record.retryCount += 1
                    record.syncStatus = retry ? .retryableFailure : .attentionRequired
                    record.failureCategory = retry ? .unavailable : .validation; try? await queue.update(record)
                }
                if retry { retryableFailures += 1 } else { nonRetryableFailures += 1 }
            }
        }
        return .init(attempted: attempted, succeeded: succeeded, retryableFailures: retryableFailures, nonRetryableFailures: nonRetryableFailures)
    }
    private func candidateAcknowledged(_ cursor: HealthKitSyncCursor) async -> Bool {
        let acknowledged = Set(await queue.records(studyID: cursor.key.stableStudyID).filter { $0.syncStatus == .acknowledged }.map(\.clientSampleID))
        return Set(cursor.candidateRequiredSampleIDs).isSubset(of: acknowledged)
    }
    private func promote(_ cursor: inout HealthKitSyncCursor) async throws {
        cursor.committedAnchor = cursor.candidateAnchor; cursor.candidateAnchor = nil
        cursor.candidateRequiredSampleIDs = []; cursor.lastSuccessfulPromotion = now(); cursor.status = .ready
        try await cursors.save(cursor)
    }
    private func cursorKey(state: ParticipantState, identifier: String) -> HealthKitSyncCursorKey? {
        guard let enrollment = state.remoteEnrollmentID, let backend = state.studyBackendID,
              let cache = state.studyBackendDescriptorCacheKey, let revision = state.enrolledConfigurationRevision else { return nil }
        return .init(stableStudyID: state.studyID, remoteEnrollmentID: enrollment, studyBackendID: backend,
                     descriptorCacheKey: cache, healthKitIdentifier: identifier, configurationRevision: revision)
    }
    // Bounds ONLY the very first query per HealthKit identifier — once a cursor's committed
    // anchor is set (see `promote(_:)` above), `query.query(identifier:start:end:anchor:limit:)`
    // uses that anchor to fetch only samples added/changed since it, regardless of what this
    // returns on later calls. `collectionEnd` (below) is what keeps sliding forward for ongoing
    // ordinary sync — untouched by backfill configuration.
    private func collectionStart(state: ParticipantState, configuration: StudyConfiguration, end: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let studyStart = Self.parse(configuration.schedule.startDate)
        // schemaVersion < 7 configs have no `backfillDays` field at all — keep their existing,
        // unconfigurable fixed-window behavior exactly as before. schemaVersion >= 7 configs use
        // the researcher-configured value, where `nil` genuinely means "full history" now that
        // this whole function no longer clamps against `enrollmentDate` (see below).
        let effectiveBackfillDays: Int? = configuration.schemaVersion >= 7 ? configuration.healthKit.backfillDays : policy.initialHistoryDays
        guard let effectiveBackfillDays else {
            // Full history: bounded by the study's own start date when set (schedule can be
            // open-ended with no startDate), else a generous fixed floor so the query isn't
            // effectively unbounded — HealthKit has no data before the device/HealthKit itself
            // existed, so this floor is just avoiding one wastefully wide scan, not a correctness
            // requirement.
            return studyStart ?? calendar.date(byAdding: .year, value: -10, to: end) ?? end
        }
        let history = calendar.date(byAdding: .day, value: -effectiveBackfillDays, to: end) ?? end
        // Deliberately NOT clamped against `state.enrollmentDate` — that was the actual bug: a
        // "days of backfill" window exists specifically to reach data recorded BEFORE
        // enrollment, and `enrollmentDate` defaults to "now" at enrollment time, so clamping
        // against it made pre-enrollment history structurally unreachable regardless of how many
        // backfill days were configured.
        return [history, studyStart].compactMap { $0 }.max() ?? history
    }
    private func collectionEnd(configuration: StudyConfiguration, now: Date) -> Date {
        [now, Self.parse(configuration.schedule.endDate)].compactMap { $0 }.min() ?? now
    }
    // NOTE (found while implementing Workstream C, deliberately NOT fixed here — see
    // conversation): `schedule.startDate`/`.endDate` are plain "yyyy-MM-dd" strings everywhere
    // in this codebase (see `StudyConfigurationValidator.dateFormatter`), but `ISO8601DateFormatter`
    // cannot parse date-only strings (verified: returns nil for "2025-01-01"). That means
    // `Self.parse(configuration.schedule.startDate)`/`.endDate` below silently return nil today,
    // so `schedule.startDate`/`.endDate` never actually bound anything in this file — a
    // separate, pre-existing bug from the one this workstream fixes. Left as-is because fixing
    // it changes `collectionEnd`'s real bound too and has ripple effects on existing tests that
    // use unrealistic `now` fixtures relying on that bound being a no-op; flagged for a
    // follow-up fix rather than folded silently into this change.
    private static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }; return ISO8601DateFormatter().date(from: value)
    }
    private static func retryable(_ error: Error) -> Bool {
        if let value = error as? HealthKitUploadError { return value == .unavailable }
        if let value = error as? BackendError { return value == .unavailable || value == .unauthorized }
        return true
    }
    private static func add(_ a: HealthKitUploadRunResult, _ b: HealthKitUploadRunResult) -> HealthKitUploadRunResult {
        .init(attempted: a.attempted + b.attempted, succeeded: a.succeeded + b.succeeded,
              retryableFailures: a.retryableFailures + b.retryableFailures,
              nonRetryableFailures: a.nonRetryableFailures + b.nonRetryableFailures)
    }
}
