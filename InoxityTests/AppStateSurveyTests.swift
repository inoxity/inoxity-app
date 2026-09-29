import XCTest
@testable import Inoxity

private struct SurveyTestProvider: StudyConfigurationProviding {
    let configuration: StudyConfiguration
    func configuration(for studyCode: String) async throws -> StudyConfiguration { configuration }
}

@MainActor final class AppStateSurveyTests: XCTestCase {
    func testAvailableInAppSurveyRecordsOpenedAndValidCallbackCompletes() async throws {
        let context = try Context(); defer { context.cleanup() }
        let state = try await context.restoredState()
        let occurrence = try XCTUnwrap(state.surveySummary.occurrences.first { $0.status == .available })
        await state.openSurveyOccurrence(occurrence.id)
        await state.confirmInAppSurveyPresented(occurrence.id)
        XCTAssertNotNil(state.activeSurveyPresentation); XCTAssertNotNil(state.participantState?.surveyOccurrenceStates[occurrence.id]?.openedAt)
        state.handleOpenURL(try SurveyURLBuilder.callbackURL(studyID: context.study.identity.id, surveyID: occurrence.surveyID, occurrenceID: occurrence.id))
        XCTAssertNotNil(state.participantState?.surveyOccurrenceStates[occurrence.id]?.completedAt)
        XCTAssertNil(state.activeSurveyPresentation); XCTAssertEqual(state.focusedSurveyOccurrenceID, occurrence.id)
        let completed = state.participantState?.surveyOccurrenceStates[occurrence.id]?.completedAt
        state.handleOpenURL(try SurveyURLBuilder.callbackURL(studyID: context.study.identity.id, surveyID: occurrence.surveyID, occurrenceID: occurrence.id))
        XCTAssertEqual(state.participantState?.surveyOccurrenceStates[occurrence.id]?.completedAt, completed)
    }

    func testFabricatedOccurrenceAndWrongStudyDoNotMutateState() async throws {
        let context = try Context(); defer { context.cleanup() }; let state = try await context.restoredState()
        let before = state.participantState?.surveyOccurrenceStates
        state.handleOpenURL(URL(string: "inoxity://survey-complete?study_id=sleep-cognition-v2&survey_id=morning-checkin&occurrence_id=inoxity.sleep-cognition-v2.morning-checkin.20260724T0837")!)
        XCTAssertEqual(state.participantState?.surveyOccurrenceStates, before); XCTAssertNotNil(state.surveyErrorMessage)
        state.handleOpenURL(URL(string: "inoxity://survey-complete?study_id=other&survey_id=morning-checkin&occurrence_id=inoxity.other.morning-checkin.20260724T0900")!)
        XCTAssertEqual(state.participantState?.surveyOccurrenceStates, before)
    }

    func testChangingTheSleepScheduleMovesWakeAnchoredSurveysAndTheirNotifications() async throws {
        // SleepStudy with its survey moved to "8 hours after wake time", like a real sleep study's
        // afternoon check-in. The linked reminder notifies at the survey's scheduled time.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SleepStudy", withExtension: "json"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["schemaVersion"] = 6
        root["sleepSchedule"] = ["enabled": true, "promptTitle": "Your sleep", "wakeLabel": "Wake", "bedLabel": "Bed"]
        var surveys = try XCTUnwrap(root["surveys"] as? [[String: Any]])
        var schedule = try XCTUnwrap(surveys[0]["schedule"] as? [String: Any])
        schedule["anchor"] = "wakeTime"; schedule["offsetMinutes"] = 480
        surveys[0]["schedule"] = schedule; root["surveys"] = surveys
        let study = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        try StudyConfigurationValidator().validate(study)

        let suite = "AppStateSurveyTests.sleep.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsParticipantStateStore(defaults: defaults), notifications = MockNotificationService(nativeStatus: .authorized)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let now = calendar.date(from: .init(year: 2026, month: 7, day: 24, hour: 6))!
        try store.saveState(.init(studyID: study.identity.id, enrollmentDate: calendar.date(from: .init(year: 2026, month: 7, day: 1))!,
                                  onboardingComplete: true, notificationPermissionState: .requestCompleted,
                                  wakeTimeMinutes: 7 * 60, bedTimeMinutes: 23 * 60))
        store.setActiveStudyCode(study.identity.code)
        let state = AppState(container: .init(studyConfigurationProvider: SurveyTestProvider(configuration: study), participantStateStore: store,
            healthKitService: MockHealthKitService(), notificationService: notifications, systemSettingsOpener: TestSettingsOpener(),
            surveyPresenter: MockSurveyPresenter(), currentDate: { now }))
        await state.restoreEnrollment()
        await state.reconcileNotifications(force: true)
        let todayAt = { (hour: Int) in calendar.date(from: .init(year: 2026, month: 7, day: 24, hour: hour))! }
        XCTAssertTrue(state.surveySummary.occurrences.contains { $0.scheduledFor == todayAt(15) }, "wake 7:00 + 8h")
        let before = await notifications.pendingRequests()
        XCTAssertTrue(before.contains { $0.fireDate == todayAt(15) })

        state.saveSleepSchedule(wakeMinutes: 9 * 60, bedMinutes: 23 * 60)
        await state.refreshNotificationStatus(reconcileIfNeeded: true)
        XCTAssertTrue(state.surveySummary.occurrences.contains { $0.scheduledFor == todayAt(17) }, "wake 9:00 + 8h")
        XCTAssertFalse(state.surveySummary.occurrences.contains { $0.scheduledFor == todayAt(15) })
        let after = await notifications.pendingRequests()
        XCTAssertTrue(after.contains { $0.fireDate == todayAt(17) }, "notification should move to 17:00")
        XCTAssertFalse(after.contains { $0.fireDate == todayAt(15) }, "the 15:00 notification should be gone")
    }

    func testASurveyCanOnlyBeStartedOnce() async throws {
        let context = try Context(); defer { context.cleanup() }
        let state = try await context.restoredState()
        let occurrence = try XCTUnwrap(state.surveySummary.occurrences.first { $0.status == .available })
        state.requestSurveyStart(occurrence.id)
        XCTAssertEqual(state.pendingSurveyStartID, occurrence.id)
        state.cancelSurveyStart()   // "Take later" leaves it untouched and startable
        XCTAssertNil(state.pendingSurveyStartID); XCTAssertNil(state.participantState?.surveyOccurrenceStates[occurrence.id])
        state.requestSurveyStart(occurrence.id)
        await state.confirmSurveyStart(occurrence.id)
        await state.confirmInAppSurveyPresented(occurrence.id)
        state.activeSurveyPresentation = nil   // participant closes the survey without finishing
        XCTAssertEqual(state.surveySummary.occurrences.first { $0.id == occurrence.id }?.status, .opened)
        // Neither the Surveys tab nor a direct open can start it again while its window is open.
        state.requestSurveyStart(occurrence.id)
        XCTAssertNil(state.pendingSurveyStartID)
        XCTAssertEqual(state.surveyErrorMessage, "You’ve already started this survey. Each survey can only be taken once.")
        await state.openSurveyOccurrence(occurrence.id)
        XCTAssertNil(state.activeSurveyPresentation)
    }

    func testPresentationFailureDoesNotPersistOpenedAt() async throws {
        let context = try Context(name: "ActivityStudy", nowHour: 20); defer { context.cleanup() }
        context.presenter.error = SurveyRuntimeError.presentationFailed
        let state = try await context.restoredState(), occurrence = try XCTUnwrap(state.surveySummary.occurrences.first { $0.status == .available })
        await state.openSurveyOccurrence(occurrence.id)
        await state.confirmInAppSurveyPresented(occurrence.id)
        XCTAssertNil(state.participantState?.surveyOccurrenceStates[occurrence.id]); XCTAssertNotNil(state.surveyErrorMessage)
    }

    func testCallbackAfterParticipantCompletionAcceptedForPreviouslyOpenedOccurrence() async throws {
        let context = try Context(); defer { context.cleanup() }; var state = try await context.restoredState()
        let occurrence = try XCTUnwrap(state.surveySummary.occurrences.first { $0.status == .available }); await state.openSurveyOccurrence(occurrence.id)
        await state.confirmInAppSurveyPresented(occurrence.id)
        var persisted = try XCTUnwrap(context.store.loadState(for: context.study.identity.id)); persisted.participationStatus = .completed; try context.store.saveState(persisted)
        state = context.makeState(); await state.restoreEnrollment()
        state.handleOpenURL(try SurveyURLBuilder.callbackURL(studyID: context.study.identity.id, surveyID: occurrence.surveyID, occurrenceID: occurrence.id))
        XCTAssertNotNil(state.participantState?.surveyOccurrenceStates[occurrence.id]?.completedAt)
    }

    func testResetClearsSurveyRuntimeAndInvalidatesQueuedCallback() async throws {
        let context = try Context(); defer { context.cleanup() }; let state = context.makeState()
        state.handleOpenURL(URL(string: "inoxity://survey-complete?study_id=sleep-cognition-v2&survey_id=morning-checkin&occurrence_id=inoxity.sleep-cognition-v2.morning-checkin.20260724T0900")!)
        _ = await state.withdraw(.deleteExistingData); XCTAssertTrue(state.surveySummary.occurrences.isEmpty); XCTAssertNil(state.activeSurveyPresentation)
    }

    @MainActor private final class Context {
        let suite = "AppStateSurveyTests.\(UUID())", defaults: UserDefaults, store: UserDefaultsParticipantStateStore
        let study: StudyConfiguration, presenter = MockSurveyPresenter(), now: Date
        init(name: String = "SleepStudy", nowHour: Int = 10) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); store = .init(defaults: defaults)
            let url = try XCTUnwrap(Bundle(for: AppStateSurveyTests.self).url(forResource: name, withExtension: "json")); study = try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: study.schedule.timeZone)!
            now = calendar.date(from: .init(year: 2026, month: 7, day: 24, hour: nowHour))!
            let enrollment = calendar.date(from: .init(year: 2026, month: 7, day: 1))!
            try store.saveState(.init(studyID: study.identity.id, enrollmentDate: enrollment, onboardingComplete: true)); store.setActiveStudyCode(study.identity.code)
        }
        func makeState() -> AppState { AppState(container: .init(studyConfigurationProvider: SurveyTestProvider(configuration: study), participantStateStore: store, healthKitService: MockHealthKitService(), notificationService: MockNotificationService(), systemSettingsOpener: TestSettingsOpener(), surveyPresenter: presenter, currentDate: { [now] in now })) }
        func restoredState() async throws -> AppState { let state = makeState(); await state.restoreEnrollment(); return state }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }
}

final class SurveyEventQueueTests: XCTestCase {
    func testDeterministicIdentity() {
        XCTAssertEqual(SurveyEventIdentityFactory.id(occurrenceID: "abc", type: .opened), "survey-event.abc.opened")
        XCTAssertEqual(SurveyEventIdentityFactory.id(occurrenceID: "abc", type: .completed), "survey-event.abc.completed")
    }
    func testPersistenceIsolationResetAndReconciliation() async throws {
        let suite = "SurveyEventQueueTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = UserDefaultsSurveyEventQueue(defaults: defaults), opened = Date(timeIntervalSince1970: 100)
        var sleep = routedState("sleep")
        sleep.surveyOccurrenceStates["one"] = .init(occurrenceID: "one", surveyID: "daily", scheduledFor: opened,
            openedAt: opened, completedAt: opened.addingTimeInterval(60))
        try await queue.reconcile(sleep, appVersion: "1", now: opened)
        try await queue.reconcile(sleep, appVersion: "1", now: opened)
        let activity = routedState("activity")
        let record = PersistedSurveyOccurrenceState(occurrenceID: "two", surveyID: "weekly", scheduledFor: opened,
            openedAt: opened, completedAt: nil)
        try await queue.enqueueOpened(record, participant: activity, source: .presentation, appVersion: "1", now: opened)
        let restored = UserDefaultsSurveyEventQueue(defaults: defaults)
        let sleepEvents = await restored.events(for: "sleep")
        let activityEvents = await restored.events(for: "activity")
        XCTAssertEqual(sleepEvents.map(\.type), [.opened, .completed])
        XCTAssertEqual(activityEvents.count, 1)
        try await restored.reset(studyID: "sleep")
        let resetSleepEvents = await restored.events(for: "sleep")
        let retainedActivityEvents = await restored.events(for: "activity")
        XCTAssertTrue(resetSleepEvents.isEmpty)
        XCTAssertEqual(retainedActivityEvents.count, 1)
    }
    func testCorruptUnsupportedAndUnroutedDataFailSafely() async throws {
        let suite = "SurveyEventQueueTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("broken".utf8), forKey: "inoxity.survey-event-queue.v1")
        let corruptEvents = await UserDefaultsSurveyEventQueue(defaults: defaults).allEvents()
        XCTAssertTrue(corruptEvents.isEmpty)
        defaults.set(try JSONSerialization.data(withJSONObject: ["version": 99, "studies": [:]]), forKey: "inoxity.survey-event-queue.v1")
        let queue = UserDefaultsSurveyEventQueue(defaults: defaults)
        let unsupportedEvents = await queue.allEvents()
        XCTAssertTrue(unsupportedEvents.isEmpty)
        let date = Date(timeIntervalSince1970: 100)
        try await queue.enqueueOpened(.init(occurrenceID: "one", surveyID: "daily", scheduledFor: date, openedAt: date, completedAt: nil),
            participant: ParticipantState(studyID: "legacy"), source: .restoration, appVersion: "1", now: date)
        let legacyEvents = await queue.events(for: "legacy")
        XCTAssertEqual(legacyEvents.first?.syncStatus, .routingRequired)
        var routed = routedState("legacy"); routed.surveyOccurrenceStates["one"] = .init(
            occurrenceID: "one", surveyID: "daily", scheduledFor: date, openedAt: date, completedAt: nil)
        try await queue.reconcile(routed, appVersion: "1", now: date)
        let promotedEvents = await queue.events(for: "legacy")
        XCTAssertEqual(promotedEvents.first?.syncStatus, .pending)
        XCTAssertEqual(promotedEvents.first?.studyBackendID, routed.studyBackendID)
    }
    func testInjectedTimeZoneLandsOnTheQueuedEvent() async throws {
        let suite = "SurveyEventQueueTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = UserDefaultsSurveyEventQueue(defaults: defaults), opened = Date(timeIntervalSince1970: 100)
        let record = PersistedSurveyOccurrenceState(occurrenceID: "one", surveyID: "daily", scheduledFor: opened,
            openedAt: opened, completedAt: nil)
        try await queue.enqueueOpened(record, participant: routedState("study"), source: .presentation, appVersion: "1",
            now: opened, timeZone: TimeZone(identifier: "America/New_York")!)
        let events = await queue.events(for: "study")
        XCTAssertEqual(events.first?.eventTimeZoneIdentifier, "America/New_York")
    }
    private func routedState(_ studyID: String) -> ParticipantState {
        ParticipantState(studyID: studyID, enrolledConfigurationSchemaVersion: 5, enrolledConfigurationRevision: 2,
            remoteEnrollmentID: UUID(), studyBackendID: UUID(), studyBackendDescriptorCacheKey: "route.\(studyID)",
            studyBackendDescriptorRevision: 1, backendRoutingStatus: .registered)
    }
}

@MainActor private struct TestSettingsOpener: SystemSettingsOpening { func openNotificationSettings() {}; func openHealthApp() {} }
