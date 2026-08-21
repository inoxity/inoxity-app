import XCTest
@testable import Inoxity

@MainActor
final class WithdrawalRuntimeTests: XCTestCase {
    func testKeepPreservesStateAndFilesCreatesPendingEventAndCancelsOnlyStudy() async throws {
        try await withContext { context in
            var state = ParticipantState(studyID: "sleep-study", externalParticipantID: "001234")
            state.surveyOccurrenceStates["occurrence"] = .init(occurrenceID: "occurrence", surveyID: "survey", scheduledFor: context.now, openedAt: nil, completedAt: nil)
            try context.states.saveState(state)
            let other = context.request(study: "other-study"), active = context.request(study: "sleep-study")
            try await context.notifications.add([other, active])
            let event = try await context.runtime.withdraw(state, choice: .keepExistingData)
            let retained = try XCTUnwrap(context.states.loadState(for: "sleep-study"))
            XCTAssertEqual(retained.participationStatus, .withdrawn)
            XCTAssertEqual(retained.externalParticipantID, "001234")
            XCTAssertEqual(retained.surveyOccurrenceStates.count, 1)
            XCTAssertTrue(context.media.deletedStudies.isEmpty)
            XCTAssertEqual(try context.events.events(for: "sleep-study"), [event])
            XCTAssertEqual(event.syncStatus, .pending); XCTAssertEqual(event.id, event.id.lowercased())
            let remainingRequests = await context.notifications.pendingRequests()
            XCTAssertEqual(remainingRequests, [other])
        }
    }

    func testDeleteRemovesOnlyActiveStudyAndEventSurvives() async throws {
        try await withContext { context in
            let active = ParticipantState(studyID: "sleep-study"), other = ParticipantState(studyID: "activity-study")
            try context.states.saveState(active); try context.states.saveState(other)
            let event = try await context.runtime.withdraw(active, choice: .deleteExistingData)
            XCTAssertNil(try context.states.loadState(for: "sleep-study"))
            let preserved = try XCTUnwrap(context.states.loadState(for: "activity-study"))
            XCTAssertEqual(preserved.studyID, other.studyID)
            XCTAssertEqual(preserved.participantUUID, other.participantUUID)
            XCTAssertEqual(preserved.participationStatus, other.participationStatus)
            XCTAssertEqual(context.media.deletedStudies, ["sleep-study"])
            XCTAssertEqual(try context.events.events(for: "sleep-study"), [event])
            XCTAssertTrue(try context.events.events(for: "activity-study").isEmpty)
        }
    }

    private func withContext(_ body: (Context) async throws -> Void) async throws {
        let context = try Context(); defer { context.cleanup() }; try await body(context)
    }
    @MainActor private final class Context {
        let suite = "WithdrawalRuntimeTests.\(UUID())", defaults: UserDefaults, states: UserDefaultsParticipantStateStore
        let events: UserDefaultsWithdrawalEventStore, media = MockMediaStorage(), notifications = MockNotificationService()
        let now = Date(timeIntervalSince1970: 1_800_000_000); lazy var runtime = WithdrawalRuntime(stateStore: states, eventStore: events, mediaStorage: media, notifications: notifications, now: { self.now })
        init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); states = .init(defaults: defaults); events = .init(defaults: defaults) }
        func request(study: String) -> ScheduledNotification { .init(identifier: "inoxity.\(study).r.1", fireDate: now, title: "Study", body: "Activity", payload: .init(studyID: study, reminderID: "r", notificationKind: .message, surveyID: nil, occurrenceID: "1", destination: .home)) }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }
}

private struct WithdrawalTestProvider: StudyConfigurationProviding { let value: StudyConfiguration; func configuration(for studyCode: String) async throws -> StudyConfiguration { value } }
@MainActor private struct WithdrawalSettingsOpener: SystemSettingsOpening { func openNotificationSettings() {}; func openHealthApp() {} }

@MainActor
final class WithdrawalIsolationTests: XCTestCase {
    func testCancelingSharedFlowPerformsNoMutation() async throws {
        let context = try Context(); defer { context.cleanup() }
        let state = context.state(); try await state.enroll(with: "SLEEP01")
        let before = try context.store.loadState(for: context.study.identity.id)
        state.beginWithdrawal()
        state.withdrawalFlowPresented = false
        XCTAssertEqual(try context.store.loadState(for: context.study.identity.id), before)
        XCTAssertTrue(try context.events.events(for: context.study.identity.id).isEmpty)
        XCTAssertTrue(context.media.deletedStudies.isEmpty)
    }

    func testSameStudyReenrollmentBlockedUntilExplicitDeletion() async throws {
        let context = try Context(); defer { context.cleanup() }
        let state = context.state(); try await state.enroll(with: "SLEEP01")
        _ = await state.withdraw(.keepExistingData)
        do { try await state.enroll(with: "SLEEP01"); XCTFail("Expected retained data conflict") }
        catch { XCTAssertEqual(error as? WithdrawalError, .retainedDataRequiresDecision) }
        XCTAssertNotNil(state.retainedEnrollmentConflict)
        await state.deleteRetainedDataAndReenroll()
        XCTAssertEqual(state.participantState?.participationStatus, .enrolled)
        XCTAssertNil(state.retainedEnrollmentConflict)
    }

    @MainActor private final class Context {
        let suite = "WithdrawalIsolationTests.\(UUID())", defaults: UserDefaults, store: UserDefaultsParticipantStateStore
        let events: UserDefaultsWithdrawalEventStore, media = MockMediaStorage(), notifications = MockNotificationService(), study: StudyConfiguration
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); store = .init(defaults: defaults); events = .init(defaults: defaults)
            let url = try XCTUnwrap(Bundle(for: WithdrawalIsolationTests.self).url(forResource: "SleepStudy", withExtension: "json")); study = try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
        }
        func state() -> AppState {
            let runtime = WithdrawalRuntime(stateStore: store, eventStore: events, mediaStorage: media, notifications: notifications)
            return .init(container: .init(studyConfigurationProvider: WithdrawalTestProvider(value: study), participantStateStore: store,
                healthKitService: MockHealthKitService(), notificationService: notifications, systemSettingsOpener: WithdrawalSettingsOpener(),
                mediaRuntime: .init(storage: media), withdrawalEventStore: events, withdrawalService: runtime))
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }
}
