import Foundation

@MainActor
final class WithdrawalRuntime: WithdrawalServicing {
    private let stateStore: any ParticipantStatePersisting
    private let eventStore: any WithdrawalEventPersisting
    private let surveyEventQueue: any SurveyEventQueueing
    private let healthKitUploadQueue: any HealthKitUploadQueuePersisting
    private let healthKitCursorStore: any HealthKitSyncCursorPersisting
    private let mediaStorage: any MediaStoring
    private let notifications: any NotificationServicing
    private let now: @Sendable () -> Date

    init(stateStore: any ParticipantStatePersisting, eventStore: any WithdrawalEventPersisting,
         surveyEventQueue: any SurveyEventQueueing = UserDefaultsSurveyEventQueue(),
         healthKitUploadQueue: any HealthKitUploadQueuePersisting = UserDefaultsHealthKitUploadQueue(),
         healthKitCursorStore: any HealthKitSyncCursorPersisting = UserDefaultsHealthKitSyncCursorStore(),
         mediaStorage: any MediaStoring, notifications: any NotificationServicing,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore; self.eventStore = eventStore; self.surveyEventQueue = surveyEventQueue
        self.healthKitUploadQueue = healthKitUploadQueue; self.healthKitCursorStore = healthKitCursorStore; self.mediaStorage = mediaStorage
        self.notifications = notifications; self.now = now
    }

    func withdraw(_ state: ParticipantState, choice: WithdrawalChoice) async throws -> PendingWithdrawalEvent {
        guard valid(state.studyID) else { throw WithdrawalError.invalidStudyID }
        let event = PendingWithdrawalEvent(id: UUID().uuidString.lowercased(), studyID: state.studyID,
                                           choice: choice, requestedAt: now(), syncStatus: .pending,
                                           studyBackendID: state.studyBackendID,
                                           descriptorCacheKey: state.studyBackendDescriptorCacheKey,
                                           remoteEnrollmentID: state.remoteEnrollmentID,
                                           // Stricter than the survey-event creation check (which accepts
                                           // .identityVerified too) — see SyncCoordinator.run()'s withdrawal
                                           // promotion pass for why withdrawal specifically needs .registered.
                                           routingStatus: state.backendRoutingStatus == .registered ? .verified : .routingRequired)
        do { try eventStore.save(event) } catch { throw WithdrawalError.persistenceFailed }
        do {
            switch choice {
            case .keepExistingData:
                var retained = state; retained.participationStatus = .withdrawn
                retained.withdrawalChoice = choice; retained.withdrawalRequestedAt = event.requestedAt
                try stateStore.saveState(retained)
            case .deleteExistingData:
                try mediaStorage.deleteStudy(studyID: state.studyID)
                try await surveyEventQueue.reset(studyID: state.studyID)
                try await healthKitUploadQueue.reset(studyID: state.studyID)
                try await healthKitCursorStore.reset(studyID: state.studyID)
                stateStore.removeState(for: state.studyID)
            }
        } catch {
            eventStore.remove(eventID: event.id, studyID: event.studyID)
            throw error
        }
        await notifications.removePendingRequests(forStudyID: state.studyID)
        return event
    }

    func deleteRetainedLocalData(_ state: ParticipantState) async throws {
        guard valid(state.studyID) else { throw WithdrawalError.invalidStudyID }
        try mediaStorage.deleteStudy(studyID: state.studyID)
        try await surveyEventQueue.reset(studyID: state.studyID)
        try await healthKitUploadQueue.reset(studyID: state.studyID)
        try await healthKitCursorStore.reset(studyID: state.studyID)
        stateStore.removeState(for: state.studyID)
        await notifications.removePendingRequests(forStudyID: state.studyID)
    }

    private func valid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("..") && !value.contains("/") && !value.contains("\\") && URL(string: value)?.scheme == nil
    }
}
