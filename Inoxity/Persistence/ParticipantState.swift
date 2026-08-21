import Foundation

struct ParticipantState: Codable, Equatable, Sendable {
    static let currentPersistenceVersion = 9

    let persistenceVersion: Int
    let participantUUID: UUID
    let studyID: String
    var externalParticipantID: String
    let enrollmentDate: Date
    var onboardingStep: Int
    var onboardingComplete: Bool
    var participationStatus: ParticipationStatus
    var withdrawalChoice: WithdrawalChoice?
    var withdrawalRequestedAt: Date?
    var healthKitRequestState: HealthKitRequestState
    var lastLocalSyncDate: Date?
    var notificationPermissionState: NotificationPermissionState
    var lastNotificationReconciliationDate: Date?
    var lastNotificationReconciliationResult: String?
    var scheduledNotificationConfigurationFingerprint: String?
    var scheduledNotificationIdentifiers: [String]
    var surveyOccurrenceStates: [String: PersistedSurveyOccurrenceState]
    var mediaDrafts: [String: PersistedMediaDraft]
    var configurationSource: StudyConfigurationSource?
    var enrolledConfigurationSchemaVersion: Int?
    var enrolledConfigurationRevision: Int?
    var configurationCacheKey: String?
    var enrollmentAttemptID: UUID?
    var enrollmentSyncStatus: EnrollmentSyncStatus?
    var remoteParticipantID: UUID?
    var remoteEnrollmentID: UUID?
    var lastBackendSyncSummary: BackendSyncSummary?
    var studyBackendID: UUID?
    var studyBackendDescriptorCacheKey: String?
    var studyBackendDescriptorRevision: Int?
    var backendRoutingStatus: BackendRoutingStatus
    var validatedBackendIdentity: ValidatedStudyBackendIdentity?
    var studyAuthenticationNamespace: String?
    /// Minutes since midnight (0...1439). Set once the participant completes the sleep-schedule
    /// onboarding step (see `SleepScheduleConfiguration`) and editable later from Settings. Only
    /// meaningful for studies with `sleepSchedule.enabled == true`; nil otherwise.
    var wakeTimeMinutes: Int?
    var bedTimeMinutes: Int?
    /// Set once the participant taps Continue on `StudyCompletionView` (shown after crossing past
    /// `StudyConfiguration.schedule.participantDurationDays`, see `StudyProgress.isPastParticipantDuration`).
    /// nil means the completion screen hasn't been shown/acknowledged yet — including for
    /// participants who will never see it at all (open-ended studies with no fixed duration).
    var completionAcknowledgedAt: Date?
    /// Best-effort snapshot from `HealthKitServicing.readCharacteristics()`, refreshed each time
    /// `requestHealthKitAccess()` succeeds. nil until the first successful HealthKit authorization;
    /// see `HealthKitCharacteristics`'s doc comment — this is local-only, never uploaded.
    var healthKitCharacteristics: HealthKitCharacteristics?
    /// Set once, during onboarding, only for studies with `schedule.resolvedStartDateMode ==
    /// .participantSelected` (see `ParticipantStartDateView`) — the participant's own confirmed
    /// real start date, which may be in the future. Distinct from `enrollmentDate` above: that
    /// field keeps meaning "when this participant actually enrolled" for every study regardless of
    /// start-date mode, so this is never written into it and never read as a fallback for it — see
    /// `ParticipantStartDateResolver`, the only place both are consulted together.
    var participantSelectedStartDate: Date?

    init(
        persistenceVersion: Int = Self.currentPersistenceVersion,
        participantUUID: UUID = UUID(),
        studyID: String,
        externalParticipantID: String = "",
        enrollmentDate: Date = Date(),
        onboardingStep: Int = 0,
        onboardingComplete: Bool = false,
        participationStatus: ParticipationStatus = .enrolled,
        withdrawalChoice: WithdrawalChoice? = nil,
        withdrawalRequestedAt: Date? = nil,
        healthKitRequestState: HealthKitRequestState = .notRequested,
        lastLocalSyncDate: Date? = nil,
        notificationPermissionState: NotificationPermissionState = .notRequested,
        lastNotificationReconciliationDate: Date? = nil,
        lastNotificationReconciliationResult: String? = nil,
        scheduledNotificationConfigurationFingerprint: String? = nil,
        scheduledNotificationIdentifiers: [String] = [],
        surveyOccurrenceStates: [String: PersistedSurveyOccurrenceState] = [:],
        mediaDrafts: [String: PersistedMediaDraft] = [:],
        configurationSource: StudyConfigurationSource? = nil,
        enrolledConfigurationSchemaVersion: Int? = nil,
        enrolledConfigurationRevision: Int? = nil,
        configurationCacheKey: String? = nil,
        enrollmentAttemptID: UUID? = nil,
        enrollmentSyncStatus: EnrollmentSyncStatus? = nil,
        remoteParticipantID: UUID? = nil,
        remoteEnrollmentID: UUID? = nil,
        lastBackendSyncSummary: BackendSyncSummary? = nil,
        studyBackendID: UUID? = nil,
        studyBackendDescriptorCacheKey: String? = nil,
        studyBackendDescriptorRevision: Int? = nil,
        backendRoutingStatus: BackendRoutingStatus = .legacyUnrouted,
        validatedBackendIdentity: ValidatedStudyBackendIdentity? = nil,
        studyAuthenticationNamespace: String? = nil,
        wakeTimeMinutes: Int? = nil,
        bedTimeMinutes: Int? = nil,
        completionAcknowledgedAt: Date? = nil,
        healthKitCharacteristics: HealthKitCharacteristics? = nil,
        participantSelectedStartDate: Date? = nil
    ) {
        self.persistenceVersion = persistenceVersion
        self.participantUUID = participantUUID
        self.studyID = studyID
        self.externalParticipantID = externalParticipantID
        self.enrollmentDate = enrollmentDate
        self.onboardingStep = onboardingStep
        self.onboardingComplete = onboardingComplete
        self.participationStatus = participationStatus
        self.withdrawalChoice = withdrawalChoice
        self.withdrawalRequestedAt = withdrawalRequestedAt
        self.healthKitRequestState = healthKitRequestState
        self.lastLocalSyncDate = lastLocalSyncDate
        self.notificationPermissionState = notificationPermissionState
        self.lastNotificationReconciliationDate = lastNotificationReconciliationDate
        self.lastNotificationReconciliationResult = lastNotificationReconciliationResult
        self.scheduledNotificationConfigurationFingerprint = scheduledNotificationConfigurationFingerprint
        self.scheduledNotificationIdentifiers = scheduledNotificationIdentifiers
        self.surveyOccurrenceStates = surveyOccurrenceStates
        self.mediaDrafts = mediaDrafts
        self.configurationSource = configurationSource
        self.enrolledConfigurationSchemaVersion = enrolledConfigurationSchemaVersion
        self.enrolledConfigurationRevision = enrolledConfigurationRevision
        self.configurationCacheKey = configurationCacheKey
        self.enrollmentAttemptID = enrollmentAttemptID
        self.enrollmentSyncStatus = enrollmentSyncStatus
        self.remoteParticipantID = remoteParticipantID
        self.remoteEnrollmentID = remoteEnrollmentID
        self.lastBackendSyncSummary = lastBackendSyncSummary
        self.studyBackendID = studyBackendID
        self.studyBackendDescriptorCacheKey = studyBackendDescriptorCacheKey
        self.studyBackendDescriptorRevision = studyBackendDescriptorRevision
        self.backendRoutingStatus = backendRoutingStatus
        self.validatedBackendIdentity = validatedBackendIdentity
        self.studyAuthenticationNamespace = studyAuthenticationNamespace
        self.wakeTimeMinutes = wakeTimeMinutes
        self.bedTimeMinutes = bedTimeMinutes
        self.completionAcknowledgedAt = completionAcknowledgedAt
        self.healthKitCharacteristics = healthKitCharacteristics
        self.participantSelectedStartDate = participantSelectedStartDate
    }

    private enum CodingKeys: String, CodingKey {
        case persistenceVersion, participantUUID, studyID, externalParticipantID, enrollmentDate
        case onboardingStep, onboardingComplete, participationStatus, withdrawalChoice, withdrawalRequestedAt
        case healthKitRequestState, lastLocalSyncDate
        case notificationPermissionState, lastNotificationReconciliationDate, lastNotificationReconciliationResult
        case scheduledNotificationConfigurationFingerprint, scheduledNotificationIdentifiers
        case surveyOccurrenceStates
        case mediaDrafts
        case configurationSource, enrolledConfigurationSchemaVersion, enrolledConfigurationRevision, configurationCacheKey
        case enrollmentAttemptID, enrollmentSyncStatus, remoteParticipantID, remoteEnrollmentID, lastBackendSyncSummary
        case studyBackendID, studyBackendDescriptorCacheKey, studyBackendDescriptorRevision
        case backendRoutingStatus, validatedBackendIdentity, studyAuthenticationNamespace
        case wakeTimeMinutes, bedTimeMinutes, completionAcknowledgedAt, healthKitCharacteristics
        case participantSelectedStartDate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        persistenceVersion = try values.decode(Int.self, forKey: .persistenceVersion)
        participantUUID = try values.decode(UUID.self, forKey: .participantUUID)
        studyID = try values.decode(String.self, forKey: .studyID)
        externalParticipantID = try values.decode(String.self, forKey: .externalParticipantID)
        enrollmentDate = try values.decode(Date.self, forKey: .enrollmentDate)
        onboardingStep = try values.decode(Int.self, forKey: .onboardingStep)
        onboardingComplete = try values.decode(Bool.self, forKey: .onboardingComplete)
        participationStatus = try values.decode(ParticipationStatus.self, forKey: .participationStatus)
        withdrawalChoice = try values.decodeIfPresent(WithdrawalChoice.self, forKey: .withdrawalChoice)
        withdrawalRequestedAt = try values.decodeIfPresent(Date.self, forKey: .withdrawalRequestedAt)
        healthKitRequestState = try values.decodeIfPresent(HealthKitRequestState.self, forKey: .healthKitRequestState) ?? .notRequested
        lastLocalSyncDate = try values.decodeIfPresent(Date.self, forKey: .lastLocalSyncDate)
        notificationPermissionState = try values.decodeIfPresent(NotificationPermissionState.self, forKey: .notificationPermissionState) ?? .notRequested
        lastNotificationReconciliationDate = try values.decodeIfPresent(Date.self, forKey: .lastNotificationReconciliationDate)
        lastNotificationReconciliationResult = try values.decodeIfPresent(String.self, forKey: .lastNotificationReconciliationResult)
        scheduledNotificationConfigurationFingerprint = try values.decodeIfPresent(String.self, forKey: .scheduledNotificationConfigurationFingerprint)
        scheduledNotificationIdentifiers = try values.decodeIfPresent([String].self, forKey: .scheduledNotificationIdentifiers) ?? []
        surveyOccurrenceStates = try values.decodeIfPresent([String: PersistedSurveyOccurrenceState].self, forKey: .surveyOccurrenceStates) ?? [:]
        mediaDrafts = try values.decodeIfPresent([String: PersistedMediaDraft].self, forKey: .mediaDrafts) ?? [:]
        configurationSource = try values.decodeIfPresent(StudyConfigurationSource.self, forKey: .configurationSource)
        enrolledConfigurationSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .enrolledConfigurationSchemaVersion)
        enrolledConfigurationRevision = try values.decodeIfPresent(Int.self, forKey: .enrolledConfigurationRevision)
        configurationCacheKey = try values.decodeIfPresent(String.self, forKey: .configurationCacheKey)
        enrollmentAttemptID = try values.decodeIfPresent(UUID.self, forKey: .enrollmentAttemptID)
        enrollmentSyncStatus = try values.decodeIfPresent(EnrollmentSyncStatus.self, forKey: .enrollmentSyncStatus)
        remoteParticipantID = try values.decodeIfPresent(UUID.self, forKey: .remoteParticipantID)
        remoteEnrollmentID = try values.decodeIfPresent(UUID.self, forKey: .remoteEnrollmentID)
        lastBackendSyncSummary = try values.decodeIfPresent(BackendSyncSummary.self, forKey: .lastBackendSyncSummary)
        studyBackendID = try values.decodeIfPresent(UUID.self, forKey: .studyBackendID)
        studyBackendDescriptorCacheKey = try values.decodeIfPresent(String.self, forKey: .studyBackendDescriptorCacheKey)
        studyBackendDescriptorRevision = try values.decodeIfPresent(Int.self, forKey: .studyBackendDescriptorRevision)
        backendRoutingStatus = try values.decodeIfPresent(BackendRoutingStatus.self, forKey: .backendRoutingStatus) ?? .legacyUnrouted
        validatedBackendIdentity = try values.decodeIfPresent(ValidatedStudyBackendIdentity.self, forKey: .validatedBackendIdentity)
        studyAuthenticationNamespace = try values.decodeIfPresent(String.self, forKey: .studyAuthenticationNamespace)
        wakeTimeMinutes = try values.decodeIfPresent(Int.self, forKey: .wakeTimeMinutes)
        bedTimeMinutes = try values.decodeIfPresent(Int.self, forKey: .bedTimeMinutes)
        completionAcknowledgedAt = try values.decodeIfPresent(Date.self, forKey: .completionAcknowledgedAt)
        healthKitCharacteristics = try values.decodeIfPresent(HealthKitCharacteristics.self, forKey: .healthKitCharacteristics)
        participantSelectedStartDate = try values.decodeIfPresent(Date.self, forKey: .participantSelectedStartDate)
    }

    func migratedToCurrentVersion() -> ParticipantState {
        ParticipantState(
            participantUUID: participantUUID,
            studyID: studyID,
            externalParticipantID: externalParticipantID,
            enrollmentDate: enrollmentDate,
            onboardingStep: onboardingStep,
            onboardingComplete: onboardingComplete,
            participationStatus: participationStatus,
            withdrawalChoice: withdrawalChoice,
            withdrawalRequestedAt: withdrawalRequestedAt,
            healthKitRequestState: healthKitRequestState,
            lastLocalSyncDate: lastLocalSyncDate,
            notificationPermissionState: notificationPermissionState,
            lastNotificationReconciliationDate: lastNotificationReconciliationDate,
            lastNotificationReconciliationResult: lastNotificationReconciliationResult,
            scheduledNotificationConfigurationFingerprint: scheduledNotificationConfigurationFingerprint,
            scheduledNotificationIdentifiers: scheduledNotificationIdentifiers,
            surveyOccurrenceStates: surveyOccurrenceStates,
            mediaDrafts: mediaDrafts,
            configurationSource: configurationSource,
            enrolledConfigurationSchemaVersion: enrolledConfigurationSchemaVersion,
            enrolledConfigurationRevision: enrolledConfigurationRevision,
            configurationCacheKey: configurationCacheKey,
            enrollmentAttemptID: enrollmentAttemptID,
            enrollmentSyncStatus: enrollmentSyncStatus,
            remoteParticipantID: remoteParticipantID,
            remoteEnrollmentID: remoteEnrollmentID,
            lastBackendSyncSummary: lastBackendSyncSummary,
            studyBackendID: studyBackendID,
            studyBackendDescriptorCacheKey: studyBackendDescriptorCacheKey,
            studyBackendDescriptorRevision: studyBackendDescriptorRevision,
            backendRoutingStatus: persistenceVersion < Self.currentPersistenceVersion ? .legacyUnrouted : backendRoutingStatus,
            validatedBackendIdentity: persistenceVersion < Self.currentPersistenceVersion ? nil : validatedBackendIdentity,
            studyAuthenticationNamespace: persistenceVersion < Self.currentPersistenceVersion ? nil : studyAuthenticationNamespace,
            wakeTimeMinutes: wakeTimeMinutes,
            bedTimeMinutes: bedTimeMinutes,
            completionAcknowledgedAt: completionAcknowledgedAt,
            healthKitCharacteristics: healthKitCharacteristics,
            participantSelectedStartDate: participantSelectedStartDate
        )
    }
}

enum ParticipationStatus: String, Codable, Equatable, Sendable {
    case enrolled, completed, withdrawn
}

struct LegacyEnrollmentState: Equatable, Sendable {
    let studyCode: String
    let participantID: String
    let onboardingStep: Int
    let onboardingComplete: Bool
}
