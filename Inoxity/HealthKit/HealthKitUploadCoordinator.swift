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
                let end = collectionEnd(state: state, configuration: configuration, now: now())
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
        let stillNeeded = Set(await cursors.cursors(studyID: state.studyID).flatMap(\.candidateRequiredSampleIDs))
        try? await queue.pruneAcknowledged(studyID: state.studyID, keeping: stillNeeded)
        return counters
    }

    private func uploadQueued(studyID: String, repository: any HealthKitSampleUploadRepository) async -> HealthKitUploadRunResult {
        let eligible = await queue.records(studyID: studyID).filter {
            $0.syncStatus == .pending || $0.syncStatus == .retryableFailure
                || ($0.syncStatus == .attentionRequired && $0.setAsideAfterRejection != true)
        }
        var counters = HealthKitUploadRunResult(attempted: 0, succeeded: 0, retryableFailures: 0, nonRetryableFailures: 0)
        // Batched per metric, so one metric's failing batch can't hold up another metric's cursor.
        for identifier in Set(eligible.map(\.healthKitIdentifier)).sorted() {
            let records = eligible.filter { $0.healthKitIdentifier == identifier }
                .sorted { ($0.sampleStart, $0.clientSampleID) < ($1.sampleStart, $1.clientSampleID) }
            for offset in stride(from: 0, to: records.count, by: policy.maximumUploadBatchSize) {
                let batch = Array(records[offset..<min(offset + policy.maximumUploadBatchSize, records.count)])
                let outcome = await submit(batch, repository: repository)
                counters = Self.add(counters, outcome.counters)
                if outcome.stop == .allMetrics { return counters }
                if outcome.stop == .thisMetric { break }
            }
        }
        return counters
    }
    private enum UploadStop { case none, thisMetric, allMetrics }
    /// Submits one batch. A sample-level rejection bisects the batch until the offending sample(s)
    /// are isolated and set aside, so the rest still upload. A retryable failure stops this metric
    /// for this pass; a systemic failure (enrollment/backend identity) stops the whole pass and
    /// leaves every record as it was for a later retry.
    private func submit(_ batch: [HealthKitSampleUpload], repository: any HealthKitSampleUploadRepository) async -> (counters: HealthKitUploadRunResult, stop: UploadStop) {
        do {
            let response = try await repository.submitHealthKitSamples(batch)
            let acknowledged = Dictionary(response.acknowledgments.map { ($0.clientSampleID, $0) }, uniquingKeysWith: { first, _ in first })
            var succeeded = 0, retryableFailures = 0
            for var record in batch {
                record.lastAttemptAt = now()
                if let ack = acknowledged[record.clientSampleID] {
                    record.syncStatus = .acknowledged; record.acknowledgedAt = ack.receivedAt
                    record.remoteAcknowledgmentID = ack.acknowledgmentID; record.failureCategory = nil; succeeded += 1
                } else { record.syncStatus = .retryableFailure; record.retryCount += 1; record.failureCategory = .unavailable; retryableFailures += 1 }
                try? await queue.update(record)
            }
            return (.init(attempted: 1, succeeded: succeeded, retryableFailures: retryableFailures, nonRetryableFailures: 0), .none)
        } catch let error where Self.sampleRejection(error) {
            guard batch.count > 1 else {
                var record = batch[0]
                record.lastAttemptAt = now(); record.retryCount += 1; record.syncStatus = .attentionRequired
                record.failureCategory = .validation; record.setAsideAfterRejection = true; try? await queue.update(record)
                return (.init(attempted: 1, succeeded: 0, retryableFailures: 0, nonRetryableFailures: 1), .none)
            }
            let middle = batch.count / 2
            let first = await submit(Array(batch[..<middle]), repository: repository)
            var counters = Self.add(.init(attempted: 1, succeeded: 0, retryableFailures: 0, nonRetryableFailures: 0), first.counters)
            guard first.stop == .none else { return (counters, first.stop) }
            let second = await submit(Array(batch[middle...]), repository: repository)
            counters = Self.add(counters, second.counters)
            return (counters, second.stop)
        } catch let error where Self.retryable(error) {
            for var record in batch {
                record.lastAttemptAt = now(); record.retryCount += 1
                if record.syncStatus != .attentionRequired { record.syncStatus = .retryableFailure }
                record.failureCategory = .unavailable; try? await queue.update(record)
            }
            return (.init(attempted: 1, succeeded: 0, retryableFailures: 1, nonRetryableFailures: 0), .thisMetric)
        } catch {
            return (.init(attempted: 1, succeeded: 0, retryableFailures: 0, nonRetryableFailures: 1), .allMetrics)
        }
    }
    /// A sample the Study Backend rejected on its own is "resolved" for cursor purposes — it can
    /// never be acknowledged, and waiting on it would freeze this metric permanently.
    private func candidateAcknowledged(_ cursor: HealthKitSyncCursor) async -> Bool {
        let resolved = Set(await queue.records(studyID: cursor.key.stableStudyID).filter {
            $0.syncStatus == .acknowledged || $0.setAsideAfterRejection == true
        }.map(\.clientSampleID))
        return Set(cursor.candidateRequiredSampleIDs).isSubset(of: resolved)
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
    /// How long after the study's last day Apple Health samples are still collected: until noon
    /// the next day, so the final night of sleep (and overnight heart rate, HRV, etc.) is captured
    /// whole instead of being cut at midnight. Reminders and surveys get no grace period.
    static let postStudyGraceHours = 12

    /// The collection window ends at the earliest of now and the study's end plus
    /// `postStudyGraceHours`. The study's end is the earlier of the study-wide `endDate` and the end
    /// of this participant's own last day (`participantDurationDays`, the same boundary that stops
    /// reminders and shows the completion screen). A sample counts if it STARTS before the window
    /// ends. Samples recorded in time but synced to HealthKit later, e.g. by a watch, still upload.
    /// Computed in the phone's current zone, like the reminder schedule.
    private func collectionEnd(state: ParticipantState, configuration: StudyConfiguration, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let studyEnd = Self.endOfDay(configuration.schedule.endDate, calendar: calendar)
        let durationEnd = StudyProgress.participantCollectionEnd(
            startDate: ParticipantStartDateResolver.resolve(schedule: configuration.schedule, participant: state, calendar: calendar),
            participantDurationDays: configuration.schedule.participantDurationDays, calendar: calendar)
        guard let lastMoment = [studyEnd, durationEnd].compactMap({ $0 }).min() else { return now }
        // lastMoment is 23:59:59 on the last day, so one second later is midnight starting the next.
        let dayAfter = lastMoment.addingTimeInterval(1)
        let graceEnd = calendar.date(byAdding: .hour, value: Self.postStudyGraceHours, to: dayAfter) ?? lastMoment
        return min(now, graceEnd)
    }
    /// The last moment of a plain "yyyy-MM-dd" schedule date (the format `StudyConfigurationValidator`
    /// enforces).
    private static func endOfDay(_ value: String?, calendar: Calendar) -> Date? {
        let parts = value?.split(separator: "-").compactMap { Int($0) } ?? []
        guard parts.count == 3, let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return next.addingTimeInterval(-1)
    }
    // NOTE (found while implementing Workstream C, still NOT fixed for the start date):
    // `schedule.startDate` is a plain "yyyy-MM-dd" string, which `ISO8601DateFormatter` can't parse
    // (it returns nil for "2025-01-01"), so `Self.parse(configuration.schedule.startDate)` in
    // `collectionStart` silently never bounds the backfill window. Fixing that would change how
    // far back backfill reaches, so it's left for a deliberate follow-up. The END date has its
    // own correct parser above (`endOfDay`).
    private static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }; return ISO8601DateFormatter().date(from: value)
    }
    private static func sampleRejection(_ error: Error) -> Bool {
        guard let value = error as? HealthKitUploadError else { return false }
        return value == .invalidSample || value == .conflictingDuplicate
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
