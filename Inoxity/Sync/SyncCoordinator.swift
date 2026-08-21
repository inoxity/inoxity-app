import Foundation

enum SyncPhase: String, Codable, Equatable, Sendable {
    case idle, restoreControlSession, resolveStudyBootstrap, validateStudyBackend, restoreStudySession
    case registerProvisionalEnrollment, synchronizeWithdrawals, synchronizeSurveyEvents, detectConfigurationRevision, completed, failed
}
struct SyncResult: Codable, Equatable, Sendable {
    let startedAt, completedAt: Date
    let operationsAttempted, operationsSucceeded, retryableFailures, nonRetryableFailures: Int
}
protocol SyncClock: Sendable { func now() -> Date }
struct SystemSyncClock: SyncClock { func now() -> Date { Date() } }
protocol SyncSleeping: Sendable { func sleep(seconds: TimeInterval) async }
struct TaskSyncSleeper: SyncSleeping { func sleep(seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) } }
struct SyncRetryPolicy: Sendable { let delays: [TimeInterval]; static let foreground = SyncRetryPolicy(delays: [0, 1, 2]) }

protocol StudyBackendRouting: Sendable {
    func context(for state: ParticipantState) async throws -> StudyBackendContext
    func context(for event: PendingWithdrawalEvent) async throws -> StudyBackendContext
    func context(for event: SurveyEventUpload) async throws -> StudyBackendContext
}

actor CachedStudyBackendRouter: StudyBackendRouting {
    private let cache: any StudyBootstrapCaching
    private let factory: any StudyBackendClientFactory
    private let environment: BackendEnvironmentName
    init(cache: any StudyBootstrapCaching, factory: any StudyBackendClientFactory, environment: BackendEnvironmentName) {
        self.cache = cache; self.factory = factory; self.environment = environment
    }
    func context(for state: ParticipantState) async throws -> StudyBackendContext {
        guard state.backendRoutingStatus != .legacyUnrouted,
              let backendID = state.studyBackendID,
              let key = state.studyBackendDescriptorCacheKey,
              let resolved = try await cache.bootstrap(cacheKey: key, environment: environment,
                                                       studyID: state.studyID, backendID: backendID) else {
            throw BackendError.routingRequired
        }
        return try await factory.context(for: resolved)
    }
    func context(for event: PendingWithdrawalEvent) async throws -> StudyBackendContext {
        guard event.routingStatus == .verified, let backendID = event.studyBackendID,
              let key = event.descriptorCacheKey,
              let resolved = try await cache.bootstrap(cacheKey: key, environment: environment,
                                                       studyID: event.studyID, backendID: backendID) else {
            throw BackendError.routingRequired
        }
        return try await factory.context(for: resolved)
    }
    func context(for event: SurveyEventUpload) async throws -> StudyBackendContext {
        guard let backendID = event.studyBackendID, let key = event.descriptorCacheKey,
              let resolved = try await cache.bootstrap(cacheKey: key, environment: environment,
                                                       studyID: event.stableStudyID, backendID: backendID) else {
            throw BackendError.routingRequired
        }
        return try await factory.context(for: resolved)
    }
}

actor SyncCoordinator: SyncCoordinating {
    private let router: any StudyBackendRouting
    private let participantStore: any ParticipantStatePersisting
    private let eventStore: any WithdrawalEventPersisting
    private let surveyEventQueue: any SurveyEventQueueing
    private let configurationProvider: (any StudyConfigurationProviding)?
    private let healthKitUploads: (any HealthKitUploadCoordinating)?
    private let installationID: any InstallationIdentifying
    private let clock: any SyncClock; private let sleeper: any SyncSleeping
    private let retryPolicy: SyncRetryPolicy; private let logger: any BackendLogging
    private var inFlight: Task<SyncResult, Never>?

    init(router: any StudyBackendRouting, participantStore: any ParticipantStatePersisting,
         eventStore: any WithdrawalEventPersisting, surveyEventQueue: any SurveyEventQueueing,
         configurationProvider: (any StudyConfigurationProviding)? = nil,
         healthKitUploads: (any HealthKitUploadCoordinating)? = nil,
         installationID: any InstallationIdentifying,
         clock: any SyncClock = SystemSyncClock(), sleeper: any SyncSleeping = TaskSyncSleeper(),
         retryPolicy: SyncRetryPolicy = .foreground, logger: any BackendLogging = SanitizedLogger()) {
        self.router = router; self.participantStore = participantStore; self.eventStore = eventStore
        self.surveyEventQueue = surveyEventQueue
        self.configurationProvider = configurationProvider; self.healthKitUploads = healthKitUploads
        self.installationID = installationID; self.clock = clock; self.sleeper = sleeper
        self.retryPolicy = retryPolicy; self.logger = logger
    }

    func synchronizePendingLocalChanges() async -> SyncResult {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.run() }; inFlight = task
        let result = await task.value; inFlight = nil; return result
    }

    func syncSleepSchedule(wakeMinutes: Int, bedMinutes: Int, for state: ParticipantState) async {
        do {
            let context = try await retry { try await self.router.context(for: state) }
            try await retry { try await context.enrollments.updateSleepSchedule(wakeMinutes: wakeMinutes, bedMinutes: bedMinutes) }
        } catch {
            logger.record(category: "sleep-schedule-sync", outcome: "retry-needed", failure: .unavailable)
        }
    }

    func syncParticipantIdentifier(_ value: String, for state: ParticipantState) async {
        do {
            let context = try await retry { try await self.router.context(for: state) }
            try await retry { try await context.enrollments.updateParticipantIdentifier(value) }
        } catch {
            logger.record(category: "participant-identifier-sync", outcome: "retry-needed", failure: .unavailable)
        }
    }

    func syncParticipantCharacteristics(_ value: HealthKitCharacteristics, for state: ParticipantState) async {
        do {
            let context = try await retry { try await self.router.context(for: state) }
            try await retry { try await context.enrollments.updateParticipantCharacteristics(value) }
        } catch {
            logger.record(category: "participant-characteristics-sync", outcome: "retry-needed", failure: .unavailable)
        }
    }

    private func run() async -> SyncResult {
        let started = clock.now(); var attempted = 0, succeeded = 0, retryable = 0, nonRetryable = 0
        var states = (try? await participantStore.allStates()) ?? []
        for state in states where state.participationStatus == .enrolled && state.enrollmentSyncStatus != .registered {
            guard state.backendRoutingStatus != .legacyUnrouted && state.backendRoutingStatus != .routingRequired else { nonRetryable += 1; continue }
            guard let attempt = state.enrollmentAttemptID, let schema = state.enrolledConfigurationSchemaVersion,
                  let revision = state.enrolledConfigurationRevision, !state.externalParticipantID.isEmpty else { continue }
            attempted += 1
            do {
                let context = try await retry { try await self.router.context(for: state) }
                let installation = try await installationID.installationID()
                _ = try await retry { try await context.enrollments.ensureParticipant() }
                let remote = try await retry { try await context.enrollments.register(.init(stableStudyID: state.studyID,
                    participantIdentifier: state.externalParticipantID, enrollmentAttemptID: attempt,
                    installationID: installation, configurationSchemaVersion: schema, configurationRevision: revision)) }
                var updated = state; updated.remoteParticipantID = remote.participantID
                updated.remoteEnrollmentID = remote.enrollmentID; updated.enrollmentSyncStatus = .registered
                updated.backendRoutingStatus = .registered; try await participantStore.saveState(updated); succeeded += 1
            } catch { retryable += 1; logger.record(category: "study-enrollment", outcome: "retry-needed", failure: .unavailable) }
        }

        states = (try? await participantStore.allStates()) ?? states

        let statesByStudyID = Dictionary(states.map { ($0.studyID, $0) }, uniquingKeysWith: { first, _ in first })
        let events = (try? await eventStore.allEvents()) ?? []
        for var event in events where event.syncStatus != .acknowledged {
            // Refresh routing/enrollment identifiers from the latest participant state before
            // attempting delivery. Mirrors `UserDefaultsSurveyEventQueue`'s enqueue-time
            // promotion (SurveyModels.swift:204-213), which re-checks routing on every sync pass
            // rather than only at event-creation time — without this, an event created while
            // still `.routingRequired` (e.g. withdrawing before enrollment finished registering)
            // would stay stuck forever, since `routingStatus` was otherwise only ever set once.
            // Withdrawal needs a STRICTER bar than survey events' `.identityVerified ||
            // .registered`, though: `submit_withdrawal_request` hard-requires a non-null
            // `enrollment_id` server-side (002_study_data_rls_and_rpcs.sql), which is only
            // guaranteed populated once routing reaches `.registered` (see the enrollment
            // registration loop above, which sets `remoteEnrollmentID` and `.registered`
            // together) — `.identityVerified` alone makes no such guarantee.
            if let state = statesByStudyID[event.studyID], state.backendRoutingStatus == .registered,
               let backendID = state.studyBackendID, let cacheKey = state.studyBackendDescriptorCacheKey,
               let enrollmentID = state.remoteEnrollmentID,
               (event.routingStatus != .verified || event.remoteEnrollmentID == nil || event.studyBackendID != backendID) {
                event.studyBackendID = backendID; event.descriptorCacheKey = cacheKey
                event.remoteEnrollmentID = enrollmentID; event.routingStatus = .verified
                try? await eventStore.update(event)
            }
            guard event.routingStatus == .verified, event.remoteEnrollmentID != nil else { nonRetryable += 1; continue }
            attempted += 1
            let routedEvent = event
            do {
                let context = try await retry { try await self.router.context(for: routedEvent) }
                let requestID = try await retry { try await context.withdrawals.submit(routedEvent, remoteEnrollmentID: routedEvent.remoteEnrollmentID) }
                event.syncStatus = .acknowledged; event.lastAttemptAt = clock.now(); event.remoteRequestID = requestID
                event.failureCategory = nil; try await eventStore.update(event); succeeded += 1
            } catch {
                event.syncStatus = .retryNeeded; event.lastAttemptAt = clock.now(); event.retryCount += 1
                event.failureCategory = .unavailable; try? await eventStore.update(event); retryable += 1
            }
        }

        for state in states { try? await surveyEventQueue.reconcile(state, appVersion: Self.appVersion, now: clock.now(), timeZone: .current) }
        var acknowledgedOpened = Set((try? await surveyEventQueue.allEvents())?.filter {
            $0.type == .opened && $0.syncStatus == .acknowledged
        }.map(\.occurrenceID) ?? [])
        let surveyEvents = ((try? await surveyEventQueue.allEvents()) ?? []).sorted {
            if $0.type != $1.type { return $0.type == .opened }
            return $0.createdAt < $1.createdAt
        }
        for var event in surveyEvents where event.syncStatus != .acknowledged {
            if event.type == .completed && !acknowledgedOpened.contains(event.occurrenceID) { continue }
            guard event.syncStatus != .routingRequired, event.studyBackendID != nil,
                  event.descriptorCacheKey != nil, event.remoteEnrollmentID != nil else {
                event.syncStatus = .routingRequired; try? await surveyEventQueue.update(event); nonRetryable += 1; continue
            }
            attempted += 1; event.syncStatus = .syncing; event.lastAttemptAt = clock.now()
            try? await surveyEventQueue.update(event)
            do {
                let routedEvent = event
                let context = try await retry { try await self.router.context(for: routedEvent) }
                let acknowledgment = try await retry { try await context.surveyEvents.upload(routedEvent) }
                event.syncStatus = .acknowledged; event.acknowledgedAt = acknowledgment.receivedAt
                event.remoteAcknowledgmentID = acknowledgment.acknowledgmentID; event.failureCategory = nil
                try await surveyEventQueue.update(event); succeeded += 1
                if event.type == .opened { acknowledgedOpened.insert(event.occurrenceID) }
            } catch {
                event.syncStatus = .retryableFailure; event.retryCount += 1; event.failureCategory = .unavailable
                try? await surveyEventQueue.update(event); retryable += 1
            }
        }
        if let configurationProvider, let healthKitUploads {
            for state in states where state.backendRoutingStatus != .legacyUnrouted && state.backendRoutingStatus != .routingRequired {
                guard let code = state.validatedBackendIdentity?.normalizedStudyCode else { nonRetryable += 1; continue }
                do {
                    let context = try await router.context(for: state)
                    let configuration = try await configurationProvider.configuration(for: code)
                    let result = await healthKitUploads.synchronize(state: state, configuration: configuration,
                                                                    repository: context.healthKitSamples)
                    attempted += result.attempted; succeeded += result.succeeded
                    retryable += result.retryableFailures; nonRetryable += result.nonRetryableFailures
                } catch { retryable += 1 }
            }
        }
        // Media upload is no longer part of the background sync pass — it's a direct call
        // (AppState.uploadMediaDraft) triggered by the participant's own "Upload" tap, matching
        // v1's model, with no local queue for this coordinator to drain.
        let completed = clock.now()
        await surveyEventQueue.recordSync(at: completed)
        let result = SyncResult(startedAt: started, completedAt: completed, operationsAttempted: attempted,
                                operationsSucceeded: succeeded, retryableFailures: retryable,
                                nonRetryableFailures: nonRetryable)
        logger.record(category: "foreground-sync", outcome: retryable + nonRetryable == 0 ? "success" : "partial",
                      failure: retryable > 0 ? .unavailable : nil)
        return result
    }
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
    private func retry<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var last: Error = BackendError.unavailable
        for delay in retryPolicy.delays {
            if delay > 0 { await sleeper.sleep(seconds: delay) }
            do { return try await operation() } catch { last = error }
        }
        throw last
    }
}
