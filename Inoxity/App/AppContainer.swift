import Foundation

struct AppContainer {
    let studyConfigurationProvider: any StudyConfigurationProviding
    let participantStateStore: any ParticipantStatePersisting
    let healthKitService: any HealthKitServicing
    let notificationService: any NotificationServicing
    let notificationScheduleBuilder: NotificationScheduleBuilder
    let systemSettingsOpener: any SystemSettingsOpening
    let surveyOccurrenceBuilder: SurveyOccurrenceBuilder
    let surveyPresenter: any SurveyPresenting
    let surveyCompletionPolicy: SurveyCompletionPolicy
    let currentDate: @Sendable () -> Date
    let mediaRuntime: MediaRuntime
    let healthSummaryProvider: any HealthSummaryProviding
    let withdrawalService: any WithdrawalServicing
    let withdrawalEventStore: any WithdrawalEventPersisting
    let surveyEventQueue: any SurveyEventQueueing
    let backendEnvironment: BackendEnvironment?
    let studyBackendClientFactory: (any StudyBackendClientFactory)?
    let installationID: any InstallationIdentifying
    let syncCoordinator: (any SyncCoordinating)?
    // Lets AppState resolve a StudyBackendContext directly for a one-off call outside the full
    // sync/queue system (media upload) — same router SyncCoordinator itself uses internally,
    // mirroring the existing studyBackendClientFactory pattern already used the same way for
    // registerParticipantID's direct enrollment call.
    let router: (any StudyBackendRouting)?
    // Wakes the app to upload new Apple Health samples in the background (nil in tests and in
    // builds without a backend environment, where there is nothing to upload to).
    let healthKitBackgroundDelivery: (any HealthKitBackgroundDelivering)?

    @MainActor
    init(studyConfigurationProvider: any StudyConfigurationProviding,
         participantStateStore: any ParticipantStatePersisting,
         healthKitService: any HealthKitServicing,
         notificationService: any NotificationServicing,
         notificationScheduleBuilder: NotificationScheduleBuilder = NotificationScheduleBuilder(),
         systemSettingsOpener: any SystemSettingsOpening,
         surveyOccurrenceBuilder: SurveyOccurrenceBuilder = SurveyOccurrenceBuilder(),
         surveyPresenter: any SurveyPresenting = SurveyPresenter(),
         surveyCompletionPolicy: SurveyCompletionPolicy = .default,
         currentDate: @escaping @Sendable () -> Date = { Date() },
         mediaRuntime: MediaRuntime = MediaRuntime(storage: MediaStorage()),
         healthSummaryProvider: (any HealthSummaryProviding)? = nil,
         withdrawalEventStore: (any WithdrawalEventPersisting)? = nil,
         surveyEventQueue: (any SurveyEventQueueing)? = nil,
         withdrawalService: (any WithdrawalServicing)? = nil,
         backendEnvironment: BackendEnvironment? = nil,
         studyBackendClientFactory: (any StudyBackendClientFactory)? = nil,
         installationID: any InstallationIdentifying = KeychainInstallationIDStore(),
         syncCoordinator: (any SyncCoordinating)? = nil,
         router: (any StudyBackendRouting)? = nil,
         healthKitBackgroundDelivery: (any HealthKitBackgroundDelivering)? = nil) {
        self.studyConfigurationProvider = studyConfigurationProvider
        self.participantStateStore = participantStateStore
        self.healthKitService = healthKitService
        self.notificationService = notificationService
        self.notificationScheduleBuilder = notificationScheduleBuilder
        self.systemSettingsOpener = systemSettingsOpener
        self.surveyOccurrenceBuilder = surveyOccurrenceBuilder
        self.surveyPresenter = surveyPresenter
        self.surveyCompletionPolicy = surveyCompletionPolicy
        self.currentDate = currentDate
        self.mediaRuntime = mediaRuntime
        let events = withdrawalEventStore ?? UserDefaultsWithdrawalEventStore()
        let surveyEvents = surveyEventQueue ?? UserDefaultsSurveyEventQueue()
        self.withdrawalEventStore = events
        self.surveyEventQueue = surveyEvents
        self.healthSummaryProvider = healthSummaryProvider ?? HealthSummaryService(query: HealthKitHealthDataQueryService(), now: currentDate)
        self.withdrawalService = withdrawalService ?? WithdrawalRuntime(stateStore: participantStateStore, eventStore: events,
                                                                        surveyEventQueue: surveyEvents,
                                                                        mediaStorage: mediaRuntime.storage,
                                                                        notifications: notificationService, now: currentDate)
        self.backendEnvironment = backendEnvironment
        self.studyBackendClientFactory = studyBackendClientFactory
        self.installationID = installationID
        self.syncCoordinator = syncCoordinator
        self.router = router
        self.healthKitBackgroundDelivery = healthKitBackgroundDelivery
    }

    @MainActor static let live: AppContainer = {
        let stateStore = UserDefaultsParticipantStateStore()
        let notifications = NotificationService()
        let media = MediaRuntime(storage: MediaStorage())
        let events = UserDefaultsWithdrawalEventStore()
        let surveyEvents = UserDefaultsSurveyEventQueue()
        let healthQueue = UserDefaultsHealthKitUploadQueue()
        let healthCursors = UserDefaultsHealthKitSyncCursorStore()
        let bundled = BundledStudyConfigurationProvider()
        guard let environment = try? InfoPlistBackendEnvironmentLoader().load() else {
            return AppContainer(studyConfigurationProvider: bundled, participantStateStore: stateStore,
                                healthKitService: HealthKitService(), notificationService: notifications,
                                systemSettingsOpener: SystemSettingsOpener(), mediaRuntime: media,
                                withdrawalEventStore: events, surveyEventQueue: surveyEvents)
        }
        let controlAuth = SupabaseControlBackendAuthenticator(environment: environment)
        let studyClients = SupabaseStudyBackendClientFactory()
        let bootstrapCache = FileStudyBootstrapCache()
        let installation = KeychainInstallationIDStore()
        let router = CachedStudyBackendRouter(cache: bootstrapCache, factory: studyClients, environment: environment.name)
        let remote = SupabaseControlStudyRepository(environment: environment, authenticator: controlAuth)
        let provider = RemoteFirstStudyConfigurationProvider(remote: remote, cache: bootstrapCache,
                                                              studyClients: studyClients, environment: environment)
        let healthUploads = HealthKitUploadCoordinator(query: HealthKitAnchoredSampleQueryService(), queue: healthQueue, cursors: healthCursors)
        let sync = SyncCoordinator(router: router, participantStore: stateStore, eventStore: events,
                                   surveyEventQueue: surveyEvents, configurationProvider: provider,
                                   healthKitUploads: healthUploads, installationID: installation)
        return AppContainer(studyConfigurationProvider: provider, participantStateStore: stateStore,
                            healthKitService: HealthKitService(), notificationService: notifications,
                            notificationScheduleBuilder: NotificationScheduleBuilder(), systemSettingsOpener: SystemSettingsOpener(),
                            surveyPresenter: SurveyPresenter(), mediaRuntime: media, withdrawalEventStore: events,
                            surveyEventQueue: surveyEvents,
                            withdrawalService: WithdrawalRuntime(stateStore: stateStore, eventStore: events,
                                                                 surveyEventQueue: surveyEvents,
                                                                 healthKitUploadQueue: healthQueue,
                                                                 healthKitCursorStore: healthCursors,
                                                                 mediaStorage: media.storage, notifications: notifications),
                            backendEnvironment: environment, studyBackendClientFactory: studyClients,
                            installationID: installation, syncCoordinator: sync, router: router,
                            healthKitBackgroundDelivery: HealthKitBackgroundDelivery { _ = await sync.synchronizePendingLocalChanges() })
    }()
}
