import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    private let provider: any StudyConfigurationProviding
    private let stateStore: any ParticipantStatePersisting
    private let healthKitService: any HealthKitServicing
    private let notificationService: any NotificationServicing
    private let notificationScheduleBuilder: NotificationScheduleBuilder
    private let systemSettingsOpener: any SystemSettingsOpening
    private let surveyOccurrenceBuilder: SurveyOccurrenceBuilder
    private let surveyPresenter: any SurveyPresenting
    private let surveyCompletionPolicy: SurveyCompletionPolicy
    private let currentDate: @Sendable () -> Date
    private let mediaRuntime: MediaRuntime
    private let healthSummaryProvider: any HealthSummaryProviding
    private let withdrawalService: any WithdrawalServicing
    private let withdrawalEventStore: any WithdrawalEventPersisting
    private let surveyEventQueue: any SurveyEventQueueing
    private let studyBackendClientFactory: (any StudyBackendClientFactory)?
    private let installationID: any InstallationIdentifying
    private let syncCoordinator: (any SyncCoordinating)?
    private let backendEnvironment: BackendEnvironment?
    // Direct, one-off StudyBackendContext resolution for an already-enrolled participant —
    // used by uploadMediaDraft, mirroring how studyBackendClientFactory above is already used
    // directly (not via syncCoordinator) for the pre-enrollment registerParticipantID call.
    private let router: (any StudyBackendRouting)?

    @Published private(set) var configuration: StudyConfiguration?
    @Published private(set) var participantState: ParticipantState?
    @Published private(set) var isRestoring = true
    @Published private(set) var persistenceError: ParticipantStatePersistenceError?
    @Published private(set) var healthKitStatus: HealthKitRuntimeStatus = .notRequested
    @Published private(set) var notificationStatus: NotificationRuntimeStatus = .notRequested
    @Published private(set) var nativeNotificationStatus: NativeNotificationAuthorizationStatus = .notDetermined
    @Published private(set) var notificationPendingSummary = NotificationPendingSummary(count: 0, nextDate: nil)
    @Published private(set) var notificationDiagnostics: NotificationDiagnostics = .empty
    @Published var selectedTab: AppTab = .home
    @Published private(set) var pendingSurveyRoute: (surveyID: String, occurrenceID: String?)?
    @Published private(set) var surveySummary = SurveyRuntimeSummary()
    @Published private(set) var focusedSurveyOccurrenceID: String?
    @Published var activeSurveyPresentation: SurveyPresentationRequest?
    @Published private(set) var surveyErrorMessage: String?
    @Published private(set) var mediaSummary = MediaRuntimeSummary()
    @Published private(set) var mediaErrorMessage: String?
    @Published private(set) var mediaActionInProgress = false
    @Published private(set) var mediaUploadSuccessMessage: String?
    @Published private(set) var healthSummaryStatus: HealthSummaryRuntimeStatus = .idle
    @Published private(set) var healthSummaryLastRefresh: Date?
    @Published private(set) var dailyHealthSummaryStatus: DailyHealthSummaryRuntimeStatus = .idle
    @Published var withdrawalFlowPresented = false
    @Published var retainedEnrollmentConflict: RetainedEnrollmentConflict?
    @Published private(set) var withdrawalErrorMessage: String?
    @Published private(set) var backendSyncResult: SyncResult?
    @Published private(set) var backendActionMessage: String?
    @Published private(set) var pendingWithdrawalCount = 0
    @Published private(set) var surveyEventDiagnostics: SurveyEventQueueDiagnostics = .empty
    @Published private(set) var newerConfigurationRevision: Int?
    private var pendingResolvedStudy: ResolvedStudy?
    // Must be @Published: until participantState exists (i.e. before enrollment completes),
    // OnboardingCoordinatorView's step comes from this value, not from participantState.
    @Published private var pendingOnboardingStep = 0
    private var pendingNotificationRoute: PendingNotificationRoute?
    private var pendingSurveyCallback: (callback: SurveyCallback, receivedAt: Date)?

    var participantID: String { participantState?.externalParticipantID ?? "" }
    var onboardingComplete: Bool { participantState?.onboardingComplete ?? false }
    var onboardingStep: Int { participantState?.onboardingStep ?? pendingOnboardingStep }
    var backendEnvironmentName: String { backendEnvironment?.name.rawValue ?? "Not configured" }
    var healthKitAvailable: Bool { healthKitService.isHealthDataAvailable }
    var notificationsAvailable: Bool { notificationService.isAvailable }

    // Plain computed properties, not cached @Published state — read fresh on every access, same as
    // StudyProgress.current(...) already is from MainTabView's HomeView. Deliberately independent
    // of ParticipantState.participationStatus: that enum has an unused `.completed` case, but many
    // `== .enrolled` guards elsewhere (health summary gating, notification scheduling, sync, survey
    // occurrence eligibility) were never written expecting it — setting it here would silently start
    // treating a completed-but-still-appAccessRemainsAvailable participant as if withdrawn.
    /// The participant's resolved "day 1" (see `ParticipantStartDateResolver`) — `nil` before it's
    /// resolvable (e.g. a `.participantSelected` study before that onboarding step runs).
    var resolvedStartDate: Date? {
        guard let configuration, let participantState else { return nil }
        return ParticipantStartDateResolver.resolve(schedule: configuration.schedule, participant: participantState)
    }
    var hasCompletedStudyDuration: Bool {
        guard let configuration else { return false }
        return StudyProgress.isPastParticipantDuration(
            startDate: resolvedStartDate,
            participantDurationDays: configuration.schedule.participantDurationDays)
    }
    /// True exactly when RootView should show `WaitingForStudyStartView` instead of the normal
    /// post-onboarding app — the participant's resolved start date is still in the future. Checked
    /// before `showsCompletionTakeover` below: a participant can't have completed a study they
    /// haven't started yet, but resolving `notYetStarted` first makes that ordering explicit rather
    /// than relying on the two conditions happening to be mutually exclusive.
    var showsPreStartWaiting: Bool {
        guard let startDate = resolvedStartDate else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: currentDate()) < calendar.startOfDay(for: startDate)
    }
    /// True exactly when RootView should show the one-time StudyCompletionView takeover.
    var showsCompletionTakeover: Bool { hasCompletedStudyDuration && participantState?.completionAcknowledgedAt == nil }
    /// True once completion has been acknowledged AND the study's config says access should not
    /// continue — MainTabView renders restricted to Settings/About only, forever, from this point on.
    var isLockedAfterCompletion: Bool {
        guard let configuration, participantState?.completionAcknowledgedAt != nil else { return false }
        return !configuration.completion.appAccessRemainsAvailable
    }

    init(container: AppContainer) {
        provider = container.studyConfigurationProvider
        stateStore = container.participantStateStore
        healthKitService = container.healthKitService
        notificationService = container.notificationService
        notificationScheduleBuilder = container.notificationScheduleBuilder
        systemSettingsOpener = container.systemSettingsOpener
        surveyOccurrenceBuilder = container.surveyOccurrenceBuilder
        surveyPresenter = container.surveyPresenter
        surveyCompletionPolicy = container.surveyCompletionPolicy
        currentDate = container.currentDate
        mediaRuntime = container.mediaRuntime
        healthSummaryProvider = container.healthSummaryProvider
        withdrawalService = container.withdrawalService
        withdrawalEventStore = container.withdrawalEventStore
        surveyEventQueue = container.surveyEventQueue
        studyBackendClientFactory = container.studyBackendClientFactory
        installationID = container.installationID
        syncCoordinator = container.syncCoordinator
        backendEnvironment = container.backendEnvironment
        router = container.router
        // Wired synchronously here, not from a SwiftUI `.task` — on a cold launch triggered by
        // tapping a notification, the system can deliver `didReceive` before a `.task` closure
        // on the root view has had a chance to run, silently dropping the tap (responseHandler
        // would still be nil). AppState is constructed via @StateObject at app-struct init,
        // well before any scene/window/`.task` scheduling, so this is as early as possible.
        notificationService.setResponseHandler { [weak self] values in self?.receiveNotificationResponse(values) }
    }

    func restoreEnrollment() async {
        defer { isRestoring = false; applyPendingNotificationRouteIfPossible() }
        guard let code = stateStore.activeStudyCode else { return }
        var attemptedStudyID: String?

        do {
            let loadedConfiguration: StudyConfiguration
            var latestRevision: Int?
            var exactEnrolled: ResolvedStudy?
            if let remoteFirst = provider as? RemoteFirstStudyConfigurationProvider {
                for existing in try stateStore.allStates() where existing.participationStatus == .enrolled {
                    guard let cacheKey = existing.studyBackendDescriptorCacheKey,
                          let backendID = existing.studyBackendID,
                          let enrolled = try await remoteFirst.enrolledStudy(cacheKey: cacheKey,
                              studyID: existing.studyID, backendID: backendID),
                          enrolled.normalizedStudyCode == StudyCodeNormalizer.normalize(code) else { continue }
                    exactEnrolled = enrolled; break
                }
            }
            let loadedFromCache = exactEnrolled != nil
            if let exactEnrolled { loadedConfiguration = exactEnrolled.configuration }
            else {
                if let remoteFirst = provider as? RemoteFirstStudyConfigurationProvider {
                    let resolved = try await remoteFirst.resolvedStudy(for: code)
                    loadedConfiguration = resolved.configuration; latestRevision = resolved.configurationRevision
                } else { loadedConfiguration = try await provider.configuration(for: code) }
            }
            attemptedStudyID = loadedConfiguration.identity.id
            let loadedState = try restoredOrMigratedState(for: loadedConfiguration, code: code)
            guard loadedState.participationStatus != .withdrawn else {
                stateStore.setActiveStudyCode(nil)
                return
            }
            let enrolledConfiguration = loadedConfiguration
            configuration = enrolledConfiguration
            participantState = loadedState
            // selectedTab is in-memory-only (always resets to .home on cold launch), unlike
            // completionAcknowledgedAt/lock status which is loaded fresh from persistence right
            // above — so a participant who was already locked in a previous session needs this
            // reapplied on every restore, not just at the moment acknowledgeCompletion() first runs.
            if isLockedAfterCompletion, ![.settings, .about].contains(selectedTab) { selectedTab = .settings }
            // reconcile only constructs a fresh queue entry for an occurrence not already queued
            // (see UserDefaultsSurveyEventQueue.enqueue's early-return for existing ids) — .current
            // is a best-effort zone for that rebuild path, not necessarily the zone the participant
            // was actually in when openedAt/completedAt was first recorded, since that isn't itself
            // persisted anywhere to recover here. The normal enqueueOpened/enqueueCompleted path
            // below captures the accurate zone live, at the moment of the real event.
            try? await surveyEventQueue.reconcile(loadedState, appVersion: Self.appVersion, now: currentDate(), timeZone: .current)
            surveyEventDiagnostics = await surveyEventQueue.diagnostics(studyID: loadedState.studyID)
            if let enrolledRevision = loadedState.enrolledConfigurationRevision,
               let latestRevision, latestRevision > enrolledRevision {
                newerConfigurationRevision = latestRevision
            } else { newerConfigurationRevision = nil }
            restoreHealthKitRuntimeStatus(configuration: enrolledConfiguration, state: loadedState)
            restoreNotificationRuntimeStatus(configuration: enrolledConfiguration, state: loadedState)
            refreshSurveyRuntime()
            refreshMediaRuntime()
            processPendingSurveyCallbackIfPossible()
            applyPendingNotificationRouteIfPossible()
            await refreshNotificationStatus(reconcileIfNeeded: true)
            // The branch above only ever reads the local bootstrap cache for an
            // already-enrolled participant (its cache key is captured once, at
            // enrollment time, and never updated) — so without this, a
            // participant's schedule (including any "relative to bedtime" reminder
            // offset) stays frozen at whatever it was when they enrolled, no matter
            // what a researcher republishes. Best-effort: only runs when we took the
            // cache path (the fallback branch above already fetched fresh from the
            // network), and never blocks/fails restoreEnrollment if offline.
            if loadedFromCache {
                await refreshEnrolledConfigurationFromNetwork()
            }
        } catch let error as ParticipantStatePersistenceError {
            safelyDiscardActiveEnrollment(studyID: attemptedStudyID)
            persistenceError = error
        } catch {
            stateStore.setActiveStudyCode(nil)
            stateStore.clearLegacyEnrollment()
        }
    }

    /// Checks the backend for a newer published configuration than the one this
    /// participant is currently running, and if found, adopts it and reschedules
    /// notifications. Called after `restoreEnrollment()`'s cache-path load, and
    /// again on every foreground (`applicationDidBecomeActive()`) so a
    /// participant who never force-quits the app still picks up changes.
    private func refreshEnrolledConfigurationFromNetwork() async {
        guard let configuration, let participantState, participantState.participationStatus == .enrolled,
              let remoteFirst = provider as? RemoteFirstStudyConfigurationProvider else { return }
        guard let resolved = try? await remoteFirst.resolvedStudy(for: configuration.identity.code) else { return }
        let enrolledRevision = participantState.enrolledConfigurationRevision ?? 0
        guard resolved.configurationRevision > enrolledRevision else { return }
        self.configuration = resolved.configuration
        updateParticipantState {
            $0.enrolledConfigurationRevision = resolved.configurationRevision
            $0.enrolledConfigurationSchemaVersion = resolved.configurationSchemaVersion
            $0.configurationCacheKey = resolved.bootstrapCacheKey
            $0.studyBackendDescriptorCacheKey = resolved.bootstrapCacheKey
            $0.studyBackendDescriptorRevision = resolved.descriptor.revision
        }
        newerConfigurationRevision = nil
        guard let refreshedState = self.participantState else { return }
        restoreHealthKitRuntimeStatus(configuration: resolved.configuration, state: refreshedState)
        restoreNotificationRuntimeStatus(configuration: resolved.configuration, state: refreshedState)
        refreshSurveyRuntime()
        refreshMediaRuntime()
        await reconcileNotifications(force: true)
    }

    func enroll(with code: String) async throws {
        backendActionMessage = "Checking study…"
        let loadedConfiguration: StudyConfiguration
        if let remoteFirst = provider as? RemoteFirstStudyConfigurationProvider {
            let resolved = try await remoteFirst.resolvedStudy(for: code)
            pendingResolvedStudy = resolved; loadedConfiguration = resolved.configuration
        } else {
            loadedConfiguration = try await provider.configuration(for: code); pendingResolvedStudy = nil
        }
        if let retained = try stateStore.loadState(for: loadedConfiguration.identity.id), retained.participationStatus == .withdrawn {
            retainedEnrollmentConflict = .init(configuration: loadedConfiguration)
            throw WithdrawalError.retainedDataRequiresDecision
        }
        newerConfigurationRevision = nil
        pendingOnboardingStep = 0
        configuration = loadedConfiguration
        isRestoring = false
        persistenceError = nil
        backendActionMessage = pendingResolvedStudy?.source == .remote ? "Study found" : "Study loaded"
        guard studyBackendClientFactory == nil else { return }
        let newState = ParticipantState(studyID: loadedConfiguration.identity.id,
            configurationSource: .bundled, enrolledConfigurationSchemaVersion: loadedConfiguration.schemaVersion,
            enrolledConfigurationRevision: 1, configurationCacheKey: nil,
            enrollmentAttemptID: UUID(), enrollmentSyncStatus: .provisional)
        try stateStore.saveState(newState)
        stateStore.setActiveStudyCode(loadedConfiguration.identity.code)
        stateStore.clearLegacyEnrollment()
        participantState = newState
        isRestoring = false
        restoreHealthKitRuntimeStatus(configuration: loadedConfiguration, state: newState)
        restoreNotificationRuntimeStatus(configuration: loadedConfiguration, state: newState)
        persistenceError = nil
        refreshSurveyRuntime()
        refreshMediaRuntime()
    }

    func registerParticipantID(_ value: String) async -> Bool {
        guard let configuration,
              let validated = ParticipantIDValidator().validate(value, configuration: configuration.participantID).value else { return false }
        guard let factory = studyBackendClientFactory, let resolution = pendingResolvedStudy else {
            return saveParticipantID(validated)
        }
        let attempt = participantState?.enrollmentAttemptID ?? UUID()
        backendActionMessage = "Connecting securely…"
        do {
            let installationIdentifier = installationID
            let remote = try await Self.withTimeout(seconds: Self.backendCallTimeoutSeconds) {
                let context = try await factory.context(for: resolution)
                guard context.identity == resolution.validatedIdentity else { throw BackendError.backendIdentityMismatch }
                let installation = try await installationIdentifier.installationID()
                _ = try await context.enrollments.ensureParticipant()
                return try await context.enrollments.register(.init(stableStudyID: configuration.identity.id,
                    participantIdentifier: validated, enrollmentAttemptID: attempt, installationID: installation,
                    configurationSchemaVersion: resolution.configurationSchemaVersion,
                    configurationRevision: resolution.configurationRevision))
            }
            backendActionMessage = "Registering enrollment…"
            let state = ParticipantState(participantUUID: UUID(), studyID: configuration.identity.id,
                externalParticipantID: validated, onboardingStep: pendingOnboardingStep,
                configurationSource: resolution.source, enrolledConfigurationSchemaVersion: resolution.configurationSchemaVersion,
                enrolledConfigurationRevision: resolution.configurationRevision, configurationCacheKey: resolution.bootstrapCacheKey,
                enrollmentAttemptID: attempt, enrollmentSyncStatus: .registered,
                remoteParticipantID: remote.participantID, remoteEnrollmentID: remote.enrollmentID,
                studyBackendID: resolution.descriptor.backendID,
                studyBackendDescriptorCacheKey: resolution.bootstrapCacheKey,
                studyBackendDescriptorRevision: resolution.descriptor.revision,
                backendRoutingStatus: .registered, validatedBackendIdentity: resolution.validatedIdentity,
                studyAuthenticationNamespace: resolution.descriptor.authStorageNamespace)
            try stateStore.saveState(state); stateStore.setActiveStudyCode(configuration.identity.code)
            participantState = state; backendActionMessage = "Enrollment registered"; return true
        } catch {
            backendActionMessage = message(for: error); return false
        }
    }

    @discardableResult
    func saveParticipantID(_ value: String) -> Bool {
        guard let participantConfiguration = configuration?.participantID,
              let validated = ParticipantIDValidator().validate(value, configuration: participantConfiguration).value else { return false }
        updateParticipantState { $0.externalParticipantID = validated }
        guard participantState?.externalParticipantID == validated else { return false }
        // Best-effort — local state above is already the source of truth for what's shown in
        // the app regardless of whether this sync succeeds. Also covers onboarding's first-time
        // registration call (registerParticipantID's local-only fallback, no backend configured),
        // where syncCoordinator/participantState won't both be set yet and this simply no-ops.
        if let syncCoordinator, let state = participantState {
            Task { await syncCoordinator.syncParticipantIdentifier(validated, for: state) }
        }
        return true
    }

    func refreshHealthSummary() async {
        guard let configuration, let participantState else { healthSummaryStatus = .idle; return }
        guard participantState.participationStatus == .enrolled else {
            healthSummaryStatus = .failed(HealthSummaryError.withdrawn.localizedDescription); return
        }
        healthSummaryStatus = .loading
        do {
            let value = try await healthSummaryProvider.snapshot(configuration: configuration, participant: participantState)
            healthSummaryStatus = .loaded(value); healthSummaryLastRefresh = value.generatedAt
        } catch { healthSummaryStatus = .failed(message(for: error)) }
    }

    /// Same data source as `refreshHealthSummary()` (a local, live Apple Health read — never
    /// Supabase), just scoped to one calendar day for "See My Data"'s day-by-day navigation.
    func refreshDailyHealthSummary(day: Date) async {
        guard let configuration, let participantState else { dailyHealthSummaryStatus = .idle; return }
        guard participantState.participationStatus == .enrolled else {
            dailyHealthSummaryStatus = .failed(HealthSummaryError.withdrawn.localizedDescription); return
        }
        dailyHealthSummaryStatus = .loading
        do {
            let value = try await healthSummaryProvider.dailySnapshot(configuration: configuration, participant: participantState, day: day, timeZone: nil)
            dailyHealthSummaryStatus = .loaded(value)
        } catch { dailyHealthSummaryStatus = .failed(message(for: error)) }
    }

    func beginWithdrawal() { withdrawalErrorMessage = nil; withdrawalFlowPresented = true }

    enum WithdrawalOutcome: Equatable, Sendable { case confirmedRemotely, savedLocallyPendingSync, failed }

    /// Attempts a real server withdrawal request before reporting an outcome, instead of
    /// dismissing instantly regardless of what actually happened. Local state (kept/deleted per
    /// `choice`) is always saved first and is never blocked on the network — only the reported
    /// *outcome* waits briefly to see whether the server genuinely acknowledged it.
    func withdraw(_ choice: WithdrawalChoice) async -> WithdrawalOutcome {
        guard let participantState else { return .failed }
        let event: PendingWithdrawalEvent
        do { event = try await withdrawalService.withdraw(participantState, choice: choice) }
        catch { withdrawalErrorMessage = message(for: error); return .failed }
        clearActiveEnrollmentRuntime(); withdrawalFlowPresented = false
        // The real sync keeps running in the background regardless of whether the bounded wait
        // below times out — it is NOT the thing being raced/cancelled, so a slow-but-eventually-
        // successful sync still completes even after this function returns.
        Task { await retryBackendSync() }
        let acknowledged = await waitForWithdrawalAcknowledgment(eventID: event.id, studyID: event.studyID,
                                                                  timeout: Self.withdrawalConfirmationTimeoutSeconds)
        return acknowledged ? .confirmedRemotely : .savedLocallyPendingSync
    }

    private static let withdrawalConfirmationTimeoutSeconds: Double = 6
    private static let withdrawalPollIntervalNanoseconds: UInt64 = 400_000_000

    private func waitForWithdrawalAcknowledgment(eventID: String, studyID: String, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? withdrawalEventStore.events(for: studyID))?.first(where: { $0.id == eventID })?.syncStatus == .acknowledged {
                return true
            }
            try? await Task.sleep(nanoseconds: Self.withdrawalPollIntervalNanoseconds)
        }
        // One last check in case acknowledgment landed between the final poll and the deadline.
        return (try? withdrawalEventStore.events(for: studyID))?.first(where: { $0.id == eventID })?.syncStatus == .acknowledged
    }

    func cancelRetainedReenrollment() { retainedEnrollmentConflict = nil }

    func deleteRetainedDataAndReenroll() async {
        guard let conflict = retainedEnrollmentConflict else { return }
        do {
            guard let retained = try stateStore.loadState(for: conflict.configuration.identity.id) else { throw WithdrawalError.persistenceFailed }
            try await withdrawalService.deleteRetainedLocalData(retained)
            retainedEnrollmentConflict = nil
            try await enroll(with: conflict.configuration.identity.code)
        } catch { withdrawalErrorMessage = message(for: error) }
    }

    func saveOnboardingStep(_ value: Int) {
        if participantState == nil { pendingOnboardingStep = max(0, value) }
        else { updateParticipantState { $0.onboardingStep = max(0, value) } }
    }

    func finishOnboarding() {
        updateParticipantState { $0.onboardingComplete = true }
        Task { await refreshNotificationStatus(reconcileIfNeeded: true) }
    }

    /// Persists that the participant has seen `StudyCompletionView`. If this newly locks them
    /// (`isLockedAfterCompletion` becomes true) and the currently-selected tab wouldn't survive that
    /// (MainTabView restricts to Settings/About when locked), corrects `selectedTab` so it doesn't
    /// render with an invalid selection.
    func acknowledgeCompletion() {
        updateParticipantState { $0.completionAcknowledgedAt = self.currentDate() }
        if isLockedAfterCompletion, ![.settings, .about].contains(selectedTab) { selectedTab = .settings }
    }

    /// Called by StudyCompletionView's Continue button. Always acknowledges first — required in
    /// both `appAccessRemainsAvailable` cases: if true and this never ran, the participant would
    /// have no way back into the app (showsCompletionTakeover would just be true again on
    /// relaunch); if false, acknowledging is what transitions them into the locked-but-navigable
    /// state at all. A redirect-open failure never blocks or reverts the acknowledgement.
    func acknowledgeCompletionAndContinue() async {
        acknowledgeCompletion()
        guard let raw = configuration?.completion.redirectURL, !raw.isEmpty, let url = URL(string: raw) else { return }
        try? await surveyPresenter.open(url: url)
    }

    /// Persists the participant's wake/bed time (minutes since midnight, 0...1439) and reconciles
    /// scheduled notifications so any survey/reminder using a `.wakeTime`/`.bedTime` anchor picks up
    /// the new times right away. Safe to call again later (e.g. from Settings) to update the schedule.
    func saveSleepSchedule(wakeMinutes: Int, bedMinutes: Int) {
        updateParticipantState { $0.wakeTimeMinutes = wakeMinutes; $0.bedTimeMinutes = bedMinutes }
        refreshSurveyRuntime()
        Task { await refreshNotificationStatus(reconcileIfNeeded: true) }
        // Best-effort — local state above is already the source of truth for
        // on-device scheduling regardless of whether this sync succeeds.
        if let syncCoordinator, let state = participantState {
            Task { await syncCoordinator.syncSleepSchedule(wakeMinutes: wakeMinutes, bedMinutes: bedMinutes, for: state) }
        }
    }

    /// Persists the participant's own confirmed real start date — only collected during onboarding
    /// for studies with `schedule.resolvedStartDateMode == .participantSelected` (see
    /// `ParticipantStartDateView`, `ParticipantStartDateResolver`) — and reconciles scheduled
    /// notifications so day-in-study and any scheduled reminders immediately reflect it (including,
    /// for a future date, scheduling nothing until it arrives). Local-only for now: unlike
    /// `saveSleepSchedule`'s wake/bed time, there's no backend column yet for a researcher to see
    /// this value server-side — it only drives on-device day-numbering and notification scheduling.
    func saveParticipantSelectedStartDate(_ date: Date) {
        updateParticipantState { $0.participantSelectedStartDate = date }
        Task { await refreshNotificationStatus(reconcileIfNeeded: true) }
    }

    func requestNotificationAccess() async {
        guard let configuration, configuration.notifications.enabled,
              configuration.reminders.contains(where: { $0.enabled }) else {
            notificationStatus = .noEnabledReminders; return
        }
        guard notificationService.isAvailable else { notificationStatus = .unavailable; return }
        notificationStatus = .requesting
        do {
            let result = try await notificationService.requestAuthorization()
            switch result {
            case .completed:
                updateParticipantState { $0.notificationPermissionState = .requestCompleted }
                notificationStatus = .requestCompleted
            case .attentionNeeded(let message):
                updateParticipantState { $0.notificationPermissionState = .attentionNeeded }
                notificationStatus = .attentionNeeded(message)
            }
        } catch {
            updateParticipantState { $0.notificationPermissionState = .attentionNeeded }
            notificationStatus = .attentionNeeded(message(for: error))
        }
        await refreshNotificationStatus(reconcileIfNeeded: true)
    }

    func refreshNotificationStatus(reconcileIfNeeded: Bool = false) async {
        guard notificationService.isAvailable else {
            nativeNotificationStatus = .unavailable; notificationStatus = .unavailable; return
        }
        nativeNotificationStatus = await notificationService.authorizationStatus()
        await refreshPendingNotificationSummary()
        await refreshNotificationDiagnostics()
        if nativeNotificationStatus == .denied {
            updateParticipantState { $0.notificationPermissionState = .attentionNeeded }
            notificationStatus = .attentionNeeded("Notifications are turned off in System Settings.")
            return
        }
        if reconcileIfNeeded, [.authorized, .provisional, .ephemeral].contains(nativeNotificationStatus) {
            await reconcileNotifications(force: false)
        }
    }

    func reconcileNotifications(force: Bool = true) async {
        guard let configuration, let participantState else { return }
        guard notificationService.isAvailable else { notificationStatus = .unavailable; return }
        let native = await notificationService.authorizationStatus()
        nativeNotificationStatus = native
        guard participantState.notificationPermissionState == .requestCompleted else {
            notificationStatus = .notRequested; await refreshNotificationDiagnostics(); return
        }
        guard [.authorized, .provisional, .ephemeral].contains(native) else {
            notificationStatus = native == .denied ? .attentionNeeded("Notifications are turned off in System Settings.") : .notRequested
            return
        }
        do {
            // Reminders fire at the participant's own current local time, not a single
            // study-fixed zone — a nationwide study's "9 AM" should mean 9 AM wherever the
            // participant actually is, and should follow them automatically if they travel.
            let zone = TimeZone.current
            let now = currentDate()
            let plan = try notificationScheduleBuilder.build(configuration: configuration, participant: participantState, now: now, timeZone: zone)
            let allPending = await notificationService.pendingRequests()
            let activePending = allPending.filter { NotificationIdentifierFactory.owns($0.identifier, studyID: configuration.identity.id) }
            let expectedByID = Dictionary(uniqueKeysWithValues: plan.requests.map { ($0.identifier, $0) })
            let pendingByID = Dictionary(uniqueKeysWithValues: activePending.map { ($0.identifier, $0) })
            let persistedIDs = Set(participantState.scheduledNotificationIdentifiers)
            let pendingIDs = Set(activePending.map(\.identifier))
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let threshold = calendar.date(byAdding: .day, value: notificationScheduleBuilder.policy.replenishmentThresholdDays, to: now) ?? now
            let needsReplenishment = activePending.compactMap(\.fireDate).max().map { $0 < threshold } ?? true
            let needsWork = force || participantState.scheduledNotificationConfigurationFingerprint != plan.fingerprint ||
                persistedIDs != pendingIDs || needsReplenishment
            guard needsWork else { return }
            notificationStatus = .scheduling
            let additions = plan.requests.filter { pendingByID[$0.identifier] != $0 }
            try await notificationService.add(additions)
            let obsolete = activePending.filter { expectedByID[$0.identifier] == nil }.map(\.identifier)
            notificationService.removePendingRequests(with: obsolete)
            updateParticipantState {
                $0.scheduledNotificationIdentifiers = plan.requests.map(\.identifier)
                $0.scheduledNotificationConfigurationFingerprint = plan.fingerprint
                $0.lastNotificationReconciliationDate = now
                $0.lastNotificationReconciliationResult = plan.requests.isEmpty ? "No eligible reminders" : "Scheduled \(plan.scheduledOccurrenceCount) reminders"
            }
            notificationStatus = plan.requests.isEmpty ? .noEnabledReminders : .reconciliationSucceeded(plan.scheduledOccurrenceCount)
            await refreshPendingNotificationSummary()
            await refreshNotificationDiagnostics()
        } catch {
            notificationStatus = .reconciliationFailed(message(for: error))
            updateParticipantState { $0.lastNotificationReconciliationResult = "Failed: \(self.message(for: error))" }
            await refreshNotificationDiagnostics()
        }
    }

    func applicationDidBecomeActive() async {
        await refreshNotificationStatus(reconcileIfNeeded: true)
        refreshSurveyRuntime()
        processPendingSurveyCallbackIfPossible()
        applyPendingNotificationRouteIfPossible()
        await retryBackendSync()
        // Best-effort — picks up a republished config (e.g. a changed reminder
        // time) for a participant who foregrounds the app without ever force-
        // quitting it. See refreshEnrolledConfigurationFromNetwork() for why this
        // is otherwise never checked after enrollment.
        await refreshEnrolledConfigurationFromNetwork()
    }

    func retryBackendSync() async {
        pendingWithdrawalCount = ((try? withdrawalEventStore.allEvents()) ?? []).filter { $0.syncStatus != .acknowledged }.count
        if let participantState { surveyEventDiagnostics = await surveyEventQueue.diagnostics(studyID: participantState.studyID) }
        guard let syncCoordinator else { return }
        backendActionMessage = "Syncing…"
        let result = await syncCoordinator.synchronizePendingLocalChanges(); backendSyncResult = result
        backendActionMessage = result.retryableFailures == 0 ? "Sync completed" : "Some changes will retry later"
        pendingWithdrawalCount = ((try? withdrawalEventStore.allEvents()) ?? []).filter { $0.syncStatus != .acknowledged }.count
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static let backendCallTimeoutSeconds: Double = 20

    // Backend SDK calls have no built-in timeout and can hang indefinitely on a stuck session
    // refresh; racing them against a timeout keeps enrollment from freezing until a force-quit.
    private static func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BackendError.unavailable
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func refreshNotificationDiagnostics() async {
        guard let configuration, let participantState else { notificationDiagnostics = .empty; return }
        let zone = TimeZone.current
        let expected = notificationScheduleBuilder.fingerprint(configuration: configuration, participant: participantState, timeZone: zone)
        notificationDiagnostics = .init(authorizationStatus: nativeNotificationStatus,
            permissionRequestCompleted: participantState.notificationPermissionState == .requestCompleted,
            configuredReminderCount: configuration.reminders.filter(\.enabled).count,
            pendingRequestCount: notificationPendingSummary.count, nextFireDate: notificationPendingSummary.nextDate,
            lastReconciliationDate: participantState.lastNotificationReconciliationDate,
            lastReconciliationResult: participantState.lastNotificationReconciliationResult ?? "Never",
            fingerprintMatches: participantState.scheduledNotificationConfigurationFingerprint == expected,
            surveyRemindersEnabled: configuration.reminders.contains { $0.enabled && $0.kind == .survey },
            messageRemindersEnabled: configuration.reminders.contains { $0.enabled && $0.kind == .message })
    }

#if DEBUG
    func scheduleTestNotification() async {
        do { try await notificationService.scheduleTestNotification(after: 10); await refreshNotificationStatus() }
        catch { notificationStatus = .reconciliationFailed(message(for: error)) }
    }
#endif

    func refreshMediaRuntime() {
        guard var state = participantState else { mediaSummary = .init(); return }
        let restoredDrafts = mediaRuntime.restored(drafts: state.mediaDrafts)
        if restoredDrafts != state.mediaDrafts {
            state.mediaDrafts = restoredDrafts
            do { try stateStore.saveState(state); participantState = state }
            catch { mediaErrorMessage = MediaRuntimeError.persistenceFailure.localizedDescription }
        }
        mediaSummary = .init(drafts: Array(restoredDrafts.values).sorted { $0.createdAt > $1.createdAt })
    }

    func importMedia(loader: any MediaSelectionLoading, categoryID: String, representedDate: Date?) async {
        guard let configuration, var state = participantState,
              let category = configuration.media.categories.first(where: { $0.id == categoryID }) else {
            mediaErrorMessage = MediaRuntimeError.unknownCategory.localizedDescription; return
        }
        mediaActionInProgress = true; mediaUploadSuccessMessage = nil; defer { mediaActionInProgress = false }
        do {
            let draft = try await mediaRuntime.importSelection(loader: loader, configuration: configuration.media,
                                                               category: category, studyID: configuration.identity.id,
                                                               existing: Array(state.mediaDrafts.values),
                                                               representedDate: representedDate, now: currentDate())
            state.mediaDrafts[draft.id] = draft
            do { try stateStore.saveState(state) }
            catch { try? mediaRuntime.storage.deleteDraft(studyID: draft.studyID, draftID: draft.id); throw MediaRuntimeError.persistenceFailure }
            participantState = state; mediaErrorMessage = nil; refreshMediaRuntime()
        } catch { mediaErrorMessage = message(for: error) }
    }

    /// Direct upload, triggered by the participant's own "Upload" tap — no local queue, no
    /// background sync. Awaited inline: the caller shows "Uploading…" while this runs, and the
    /// draft either disappears (success — matches v1's behavior of not keeping a local copy
    /// after a successful upload) or ends up `.uploadFailed` with `mediaErrorMessage` set, so
    /// the same "Upload" action can simply be tapped again to retry.
    func uploadMediaDraft(_ draftID: String) async {
        guard let configuration, var state = participantState, let draft = state.mediaDrafts[draftID],
              draft.status == .ready || draft.status == .uploadFailed else { return }
        mediaUploadSuccessMessage = nil
        guard let router else {
            mediaErrorMessage = MediaRuntimeError.uploadUnavailable.localizedDescription; return
        }
        guard state.enrollmentSyncStatus == .registered, state.backendRoutingStatus == .registered,
              let remoteEnrollmentID = state.remoteEnrollmentID, let backendID = state.studyBackendID else {
            mediaErrorMessage = MediaRuntimeError.uploadUnavailable.localizedDescription; return
        }
        state.mediaDrafts[draftID]?.status = .uploading
        state.mediaDrafts[draftID]?.lastModifiedAt = currentDate()
        try? stateStore.saveState(state); participantState = state; refreshMediaRuntime()
        do {
            let context = try await router.context(for: state)
            let fileURL = try mediaRuntime.storage.mediaURL(studyID: draft.studyID, draftID: draft.id, relativePath: draft.relativeMediaPath)
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let descriptor = MediaUploadDescriptor(studyID: draft.studyID, stableStudyID: configuration.identity.id,
                draftID: draft.id, categoryID: draft.categoryID, mediaType: draft.mediaType, mimeType: draft.mimeType,
                byteCount: draft.byteCount, checksum: draft.sha256, durationSeconds: draft.durationSeconds,
                representedDate: draft.representedDate, originalFilenameExtension: draft.originalFilenameExtension,
                remoteEnrollmentID: remoteEnrollmentID, studyBackendID: backendID,
                configurationSchemaVersion: configuration.schemaVersion,
                configurationRevision: state.enrolledConfigurationRevision ?? configuration.schemaVersion)
            _ = try await context.media.upload(descriptor, data: data)
            try? mediaRuntime.storage.deleteDraft(studyID: draft.studyID, draftID: draft.id)
            state.mediaDrafts.removeValue(forKey: draftID)
            try stateStore.saveState(state); participantState = state; mediaErrorMessage = nil
            mediaUploadSuccessMessage = "Upload complete."
        } catch {
            state.mediaDrafts[draftID]?.status = .uploadFailed
            state.mediaDrafts[draftID]?.failureReason = message(for: error)
            state.mediaDrafts[draftID]?.lastModifiedAt = currentDate()
            try? stateStore.saveState(state); participantState = state
            mediaErrorMessage = message(for: error)
        }
        refreshMediaRuntime()
    }

    func retryMediaDraft(_ draftID: String) {
        guard var state = participantState, let draft = state.mediaDrafts[draftID] else { return }
        do { state.mediaDrafts[draftID] = try mediaRuntime.retry(draft, now: currentDate()); try stateStore.saveState(state); participantState = state; mediaErrorMessage = nil; refreshMediaRuntime() }
        catch { mediaErrorMessage = message(for: error) }
    }

    func deleteMediaDraft(_ draftID: String) {
        guard var state = participantState, let draft = state.mediaDrafts[draftID] else { return }
        do {
            try mediaRuntime.storage.deleteDraft(studyID: draft.studyID, draftID: draft.id)
            state.mediaDrafts.removeValue(forKey: draftID)
            try stateStore.saveState(state); participantState = state; mediaErrorMessage = nil; refreshMediaRuntime()
        } catch { mediaErrorMessage = message(for: error) }
    }

    func clearFailedMediaDrafts() {
        let ids = mediaSummary.drafts.filter { $0.status == .failed }.map(\.id)
        ids.forEach(deleteMediaDraft)
    }

    func mediaThumbnailURL(for draft: PersistedMediaDraft) -> URL? {
        guard let path = draft.relativeThumbnailPath else { return nil }
        return try? mediaRuntime.storage.thumbnailURL(studyID: draft.studyID, draftID: draft.id, relativePath: path)
    }

    func refreshSurveyRuntime() {
        guard let configuration, let participantState else { surveySummary = .init(); return }
        do {
            surveySummary.occurrences = try surveyOccurrenceBuilder.build(configuration: configuration,
                                                                           participant: participantState,
                                                                           now: currentDate(),
                                                                           timeZone: .current)
            surveyErrorMessage = nil
            focusPendingSurveyRouteIfPossible()
        } catch {
            surveySummary = .init()
            surveyErrorMessage = message(for: error)
        }
    }

    func openSurveyOccurrence(_ occurrenceID: String) async {
        refreshSurveyRuntime()
        guard participantState?.participationStatus != .withdrawn,
              let configuration, let occurrence = surveySummary.occurrences.first(where: { $0.id == occurrenceID }),
              occurrence.status == .available || occurrence.status == .opened,
              let survey = configuration.surveys.first(where: { $0.id == occurrence.surveyID && $0.enabled }) else {
            surveyErrorMessage = SurveyRuntimeError.unavailableOccurrence.localizedDescription; return
        }
        do {
            let url = try SurveyURLBuilder.build(baseURL: survey.url, studyID: configuration.identity.id,
                                                 surveyID: survey.id, occurrenceID: occurrence.id,
                                                 callbackEnabled: survey.completionCallback.enabled)
            let request = SurveyPresentationRequest(occurrenceID: occurrence.id, url: url, mode: survey.presentationMode)
            switch survey.presentationMode {
            case .externalBrowser: try await surveyPresenter.openExternal(request)
            case .inAppBrowser:
                activeSurveyPresentation = request
                focusedSurveyOccurrenceID = occurrence.id
                surveyErrorMessage = nil
                return
            }
            try await persistSurveyOpened(occurrence, source: .presentation)
            focusedSurveyOccurrenceID = occurrence.id
            surveyErrorMessage = nil
            refreshSurveyRuntime()
        } catch { surveyErrorMessage = message(for: error) }
    }

    func confirmInAppSurveyPresented(_ occurrenceID: String) async {
        guard activeSurveyPresentation?.occurrenceID == occurrenceID else { return }
        refreshSurveyRuntime()
        guard let occurrence = surveySummary.occurrences.first(where: { $0.id == occurrenceID }) else { return }
        do {
            try await persistSurveyOpened(occurrence, source: .presentation)
            focusedSurveyOccurrenceID = occurrenceID; surveyErrorMessage = nil; refreshSurveyRuntime()
        } catch { surveyErrorMessage = message(for: error) }
    }

    private func persistSurveyOpened(_ occurrence: SurveyOccurrence, source: SurveyEventSource) async throws {
        updateParticipantState { state in
            var record = state.surveyOccurrenceStates[occurrence.id] ?? .init(
                occurrenceID: occurrence.id, surveyID: occurrence.surveyID,
                scheduledFor: occurrence.scheduledFor, openedAt: nil, completedAt: nil)
            if record.openedAt == nil { record.openedAt = currentDate() }
            state.surveyOccurrenceStates[occurrence.id] = record
        }
        guard let participantState, let record = participantState.surveyOccurrenceStates[occurrence.id] else { return }
        try await surveyEventQueue.enqueueOpened(record, participant: participantState, source: source,
                                                 appVersion: Self.appVersion, now: currentDate(), timeZone: .current)
        surveyEventDiagnostics = await surveyEventQueue.diagnostics(studyID: participantState.studyID)
    }

    func handleOpenURL(_ url: URL) {
        guard SurveyCallbackParser.isCandidate(url) else { return }
        do {
            let callback = try SurveyCallbackParser.parse(url)
            pendingSurveyCallback = (callback, currentDate())
            processPendingSurveyCallbackIfPossible()
        } catch { surveyErrorMessage = message(for: error) }
    }

    private func processPendingSurveyCallbackIfPossible() {
        guard !isRestoring, let pending = pendingSurveyCallback else { return }
        pendingSurveyCallback = nil
        do { try completeSurvey(callback: pending.callback, receivedAt: pending.receivedAt) }
        catch { surveyErrorMessage = message(for: error) }
    }

    private func completeSurvey(callback: SurveyCallback, receivedAt: Date) throws {
        guard let configuration, let participantState else { throw SurveyRuntimeError.unknownOccurrence }
        guard participantState.participationStatus != .withdrawn else { throw SurveyRuntimeError.unavailableOccurrence }
        guard StudyConfigurationValidator.supportedSchemaVersions.contains(configuration.schemaVersion) else { throw SurveyRuntimeError.unsupportedConfiguration }
        guard callback.studyID == configuration.identity.id else { throw SurveyRuntimeError.wrongStudy }
        guard let survey = configuration.surveys.first(where: { $0.id == callback.surveyID && $0.enabled }) else { throw SurveyRuntimeError.unknownSurvey }
        guard survey.completionCallback.enabled else { throw SurveyRuntimeError.callbackNotEnabled }
        let occurrences = try surveyOccurrenceBuilder.build(configuration: configuration, participant: participantState, now: receivedAt)
        guard let occurrence = occurrences.first(where: { $0.id == callback.occurrenceID && $0.surveyID == callback.surveyID }),
              SurveyOccurrenceIdentifierFactory.belongs(callback.occurrenceID, studyID: callback.studyID, surveyID: callback.surveyID) else {
            throw SurveyRuntimeError.unknownOccurrence
        }
        guard let record = participantState.surveyOccurrenceStates[occurrence.id] else { throw SurveyRuntimeError.inconsistentPersistedState }
        if record.completedAt != nil { focusedSurveyOccurrenceID = occurrence.id; selectedTab = .surveys; return }
        try SurveyCompletionValidator.validate(record: record, occurrence: occurrence, receivedAt: receivedAt,
                                               policy: surveyCompletionPolicy)
        updateParticipantState { state in
            guard var value = state.surveyOccurrenceStates[occurrence.id], value.completedAt == nil else { return }
            value.completedAt = receivedAt; state.surveyOccurrenceStates[occurrence.id] = value
        }
        if let state = self.participantState, let persisted = state.surveyOccurrenceStates[occurrence.id] {
            Task { @MainActor in
                try? await self.surveyEventQueue.enqueueCompleted(persisted, participant: state,
                    source: .completionCallback, appVersion: Self.appVersion, now: receivedAt, timeZone: .current)
                self.surveyEventDiagnostics = await self.surveyEventQueue.diagnostics(studyID: state.studyID)
            }
        }
        activeSurveyPresentation = nil
        selectedTab = .surveys; focusedSurveyOccurrenceID = occurrence.id; pendingSurveyRoute = nil
        surveyErrorMessage = nil; refreshSurveyRuntime()
    }

    func openNotificationSystemSettings() { systemSettingsOpener.openNotificationSettings() }

    func requestHealthKitAccess() async {
        guard let configuration, configuration.healthKit.enabled else { return }
        guard healthKitService.isHealthDataAvailable else {
            healthKitStatus = .unavailable
            return
        }
        let identifiers = Set(configuration.healthKit.identifiers)
        let includeCharacteristics = configuration.healthKit.includeCharacteristics
        // Best-effort: if this fails we just fall back to the generic "completed" messaging below.
        let preCheck = try? await healthKitService.requestStatus(for: identifiers, includeCharacteristics: includeCharacteristics)
        do {
            let result = try await healthKitService.requestReadAuthorization(for: identifiers, includeCharacteristics: includeCharacteristics)
            // Characteristic types (biological sex, blood type, date of birth, Fitzpatrick skin
            // type, wheelchair use) are only in the read set above when this study explicitly
            // opted in — leave the stored snapshot nil otherwise (rather than an all-nil-fields
            // HealthKitCharacteristics(), which would misleadingly read as "read, but empty"
            // instead of "never attempted").
            let characteristics: HealthKitCharacteristics? = includeCharacteristics ? healthKitService.readCharacteristics() : nil
            switch result {
            case .completed:
                updateParticipantState {
                    $0.healthKitRequestState = .requestCompleted
                    $0.healthKitCharacteristics = characteristics
                }
                healthKitStatus = (preCheck == .unnecessary) ? .completedWithoutPrompt : .requestCompleted
            case .attentionNeeded(let message):
                updateParticipantState {
                    $0.healthKitRequestState = .attentionNeeded
                    $0.healthKitCharacteristics = characteristics
                }
                healthKitStatus = .attentionNeeded(message)
            }
            // Best-effort, fire-and-forget — local participantState above is already the source
            // of truth regardless of whether this sync succeeds. Only ever fires for studies that
            // opted into includeCharacteristics, and only when something was actually read.
            if let syncCoordinator, let state = participantState, let characteristics, characteristics.hasAnyValue {
                Task { await syncCoordinator.syncParticipantCharacteristics(characteristics, for: state) }
            }
        } catch {
            updateParticipantState { $0.healthKitRequestState = .attentionNeeded }
            healthKitStatus = .attentionNeeded(message(for: error))
        }
    }

    func openHealthApp() { systemSettingsOpener.openHealthApp() }

    func syncHealthKitNow() async {
        guard let configuration, configuration.healthKit.enabled else { return }
        guard healthKitService.isHealthDataAvailable else {
            healthKitStatus = .unavailable
            return
        }
        healthKitStatus = .syncing
        do {
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
            let summary = try await healthKitService.syncLocalData(
                for: Set(configuration.healthKit.identifiers),
                interval: DateInterval(start: start, end: end)
            )
            updateParticipantState { $0.lastLocalSyncDate = summary.completedAt }
            healthKitStatus = .syncSucceeded(summary)
            // Secondary trigger for the characteristics upload attempted in
            // requestHealthKitAccess() — that only naturally runs once, at onboarding, so a
            // network failure there could otherwise leave an already-read local snapshot
            // unsynced indefinitely. Re-pushes whatever's already stored locally (doesn't re-read
            // from HealthKit) whenever the participant manually syncs from Settings.
            if let syncCoordinator, let state = participantState, let characteristics = state.healthKitCharacteristics, characteristics.hasAnyValue {
                Task { await syncCoordinator.syncParticipantCharacteristics(characteristics, for: state) }
            }
        } catch {
            healthKitStatus = .syncFailed(message(for: error))
        }
    }

    func resetEnrollment() async { beginWithdrawal() }

    private func clearActiveEnrollmentRuntime() {
        stateStore.setActiveStudyCode(nil)
        stateStore.clearLegacyEnrollment()
        configuration = nil
        participantState = nil
        persistenceError = nil
        healthKitStatus = .notRequested
        notificationStatus = .notRequested
        nativeNotificationStatus = .notDetermined
        notificationPendingSummary = .init(count: 0, nextDate: nil)
        notificationDiagnostics = .empty
        selectedTab = .home; pendingSurveyRoute = nil; pendingNotificationRoute = nil
        surveySummary = .init(); focusedSurveyOccurrenceID = nil; activeSurveyPresentation = nil
        pendingSurveyCallback = nil; surveyErrorMessage = nil
        mediaSummary = .init(); mediaErrorMessage = nil; mediaActionInProgress = false; mediaUploadSuccessMessage = nil
        healthSummaryStatus = .idle; healthSummaryLastRefresh = nil; dailyHealthSummaryStatus = .idle
        newerConfigurationRevision = nil
        isRestoring = false
    }

    private func restoredOrMigratedState(for configuration: StudyConfiguration, code: String) throws -> ParticipantState {
        if let state = try stateStore.loadState(for: configuration.identity.id) { return state }
        guard let legacy = stateStore.legacyEnrollment(),
              legacy.studyCode == StudyCodeNormalizer.normalize(code) else {
            throw ParticipantStatePersistenceError.corruptData
        }
        let migrated = ParticipantState(
            studyID: configuration.identity.id,
            externalParticipantID: legacy.participantID,
            onboardingStep: legacy.onboardingStep,
            onboardingComplete: legacy.onboardingComplete
        )
        try stateStore.saveState(migrated)
        stateStore.setActiveStudyCode(configuration.identity.code)
        stateStore.clearLegacyEnrollment()
        return migrated
    }

    private func updateParticipantState(_ mutation: (inout ParticipantState) -> Void) {
        guard var state = participantState else { return }
        mutation(&state)
        do {
            try stateStore.saveState(state)
            participantState = state
            persistenceError = nil
        } catch let error as ParticipantStatePersistenceError {
            persistenceError = error
        } catch {
            persistenceError = .corruptData
        }
    }

    private func safelyDiscardActiveEnrollment(studyID: String?) {
        if let studyID { stateStore.removeState(for: studyID) }
        stateStore.setActiveStudyCode(nil)
        stateStore.clearLegacyEnrollment()
        configuration = nil
        participantState = nil
        healthKitStatus = .notRequested
        notificationStatus = .notRequested
    }

    private func restoreHealthKitRuntimeStatus(configuration: StudyConfiguration, state: ParticipantState) {
        guard configuration.healthKit.enabled else { healthKitStatus = .notRequested; return }
        guard healthKitService.isHealthDataAvailable else { healthKitStatus = .unavailable; return }
        switch state.healthKitRequestState {
        case .notRequested: healthKitStatus = .notRequested
        case .requestCompleted: healthKitStatus = .requestCompleted
        case .attentionNeeded: healthKitStatus = .attentionNeeded("Apple Health access may need your attention.")
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func restoreNotificationRuntimeStatus(configuration: StudyConfiguration, state: ParticipantState) {
        guard configuration.notifications.enabled, configuration.reminders.contains(where: { $0.enabled }) else {
            notificationStatus = .noEnabledReminders; return
        }
        guard notificationService.isAvailable else { notificationStatus = .unavailable; return }
        switch state.notificationPermissionState {
        case .notRequested: notificationStatus = .notRequested
        case .requestCompleted: notificationStatus = .requestCompleted
        case .attentionNeeded: notificationStatus = .attentionNeeded("Notification access may need your attention.")
        }
    }

    private func refreshPendingNotificationSummary() async {
        guard let studyID = configuration?.identity.id else { notificationPendingSummary = .init(count: 0, nextDate: nil); return }
        let active = await notificationService.pendingRequests().filter { NotificationIdentifierFactory.owns($0.identifier, studyID: studyID) }
        notificationPendingSummary = .init(count: active.count, nextDate: active.map(\.fireDate).min())
    }

    private func receiveNotificationResponse(_ values: [String: String]) {
        guard let route = NotificationRouteParser.route(from: values) else {
            if configuration != nil { selectedTab = .home }
            return
        }
        pendingNotificationRoute = route
        applyPendingNotificationRouteIfPossible()
    }

    private func applyPendingNotificationRouteIfPossible() {
        guard !isRestoring, let configuration, let route = pendingNotificationRoute else { return }
        // A locked participant's MainTabView only ever renders [.settings, .about] (see
        // isLockedAfterCompletion) — a stale scheduled notification tapped after lock could
        // otherwise route selectedTab to a tab that's no longer part of that hardcoded list.
        guard !isLockedAfterCompletion else { pendingNotificationRoute = nil; return }
        guard route.studyID == configuration.identity.id else { pendingNotificationRoute = nil; return }
        let visible = Set(configuration.features.visibleTabs)
        switch route.destination {
        case .home: selectedTab = .home
        case .settings: selectedTab = visible.contains(.settings) ? .settings : .home
        case .aboutStudy: selectedTab = visible.contains(.about) ? .about : .home
        case .surveys:
            selectedTab = configuration.features.surveysEnabled && visible.contains(.surveys) ? .surveys : .home
        case .survey(let surveyID, let occurrenceID):
            if configuration.features.surveysEnabled, visible.contains(.surveys),
               configuration.surveys.contains(where: { $0.id == surveyID && $0.enabled }) {
                selectedTab = .surveys; pendingSurveyRoute = (surveyID, occurrenceID)
            } else { selectedTab = .home }
        }
        pendingNotificationRoute = nil
        focusPendingSurveyRouteIfPossible()
    }

    private func focusPendingSurveyRouteIfPossible() {
        guard let route = pendingSurveyRoute else { return }
        let candidates = surveySummary.occurrences.filter { $0.surveyID == route.surveyID }
        if let id = route.occurrenceID {
            guard let occurrence = candidates.first(where: { $0.id == id }),
                  occurrence.status == .available || occurrence.status == .opened else {
                focusedSurveyOccurrenceID = nil; pendingSurveyRoute = nil
                surveyErrorMessage = "The requested survey is no longer available."
                return
            }
            focusedSurveyOccurrenceID = id; pendingSurveyRoute = nil
            // A notification tap always carries the specific occurrence — open it
            // directly rather than just scrolling/highlighting its card in the
            // Surveys list and waiting for a second manual tap.
            Task { await openSurveyOccurrence(id) }
        } else {
            let available = candidates.filter { $0.status == .available || $0.status == .opened }
            focusedSurveyOccurrenceID = available.count == 1 ? available[0].id : nil
        }
    }
}
