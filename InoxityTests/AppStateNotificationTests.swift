import XCTest
@testable import Inoxity

private struct NotificationTestProvider: StudyConfigurationProviding {
    let configuration: StudyConfiguration
    func configuration(for studyCode: String) async throws -> StudyConfiguration { configuration }
}
@MainActor private struct MockSettingsOpener: SystemSettingsOpening { func openNotificationSettings() {}; func openHealthApp() {} }

@MainActor final class AppStateNotificationTests: XCTestCase {
    func testPermissionIsExplicitAndDenialIsNonblocking() async throws {
        let context = try Context(status: .notDetermined); defer { context.cleanup() }
        let state = context.state(); try await state.enroll(with: "SLEEP01")
        await state.applicationDidBecomeActive()
        XCTAssertEqual(context.notifications.requestAuthorizationCallCount, 0)
        let pendingRequests = await context.notifications.pendingRequests()
        XCTAssertTrue(pendingRequests.isEmpty)
        context.notifications.nativeStatus = .denied
        await state.requestNotificationAccess()
        XCTAssertTrue(state.configuration != nil); XCTAssertEqual(state.notificationStatus, .attentionNeeded("Notifications are turned off in System Settings."))
        XCTAssertEqual(state.participantState?.notificationPermissionState, .attentionNeeded)
    }

    func testDisabledOrUnavailableNotificationsDoNotRequestPermission() async throws {
        let disabled = try Context(disableNotifications: true); defer { disabled.cleanup() }
        let disabledState = disabled.state(); try await disabledState.enroll(with: "SLEEP01"); await disabledState.requestNotificationAccess()
        XCTAssertEqual(disabled.notifications.requestAuthorizationCallCount, 0)
        let unavailable = try Context(available: false); defer { unavailable.cleanup() }
        let unavailableState = unavailable.state(); try await unavailableState.enroll(with: "SLEEP01"); await unavailableState.requestNotificationAccess()
        XCTAssertEqual(unavailable.notifications.requestAuthorizationCallCount, 0); XCTAssertEqual(unavailableState.notificationStatus, .unavailable)
    }

    func testSuccessfulReconciliationIsIdempotentAndPersistsFacts() async throws {
        let context = try Context(); defer { context.cleanup() }
        let state = context.state(); try await state.enroll(with: "SLEEP01")
        await state.requestNotificationAccess()
        let firstAdded = context.notifications.addedBatches.flatMap { $0 }.count
        XCTAssertGreaterThan(firstAdded, 0); XCTAssertNotNil(state.participantState?.scheduledNotificationConfigurationFingerprint)
        XCTAssertNotNil(state.participantState?.lastNotificationReconciliationDate)
        let identifiers = state.participantState?.scheduledNotificationIdentifiers ?? []
        await state.reconcileNotifications(force: false)
        XCTAssertEqual(context.notifications.addedBatches.flatMap { $0 }.count, firstAdded)
        XCTAssertEqual(state.participantState?.scheduledNotificationIdentifiers, identifiers)
    }

    func testReconciliationAddsMissingRemovesObsoleteAndPreservesOtherStudy() async throws {
        let context = try Context(); defer { context.cleanup() }
        let obsolete = context.request(id: "inoxity.sleep-cognition-v2.old.1", study: "sleep-cognition-v2")
        let other = context.request(id: "inoxity.other-study.r.1", study: "other-study")
        try await context.notifications.add([obsolete, other])
        let state = context.state(); try await state.enroll(with: "SLEEP01"); await state.requestNotificationAccess(); await state.reconcileNotifications(force: true)
        let pending = await context.notifications.pendingRequests()
        XCTAssertFalse(pending.contains(obsolete)); XCTAssertTrue(pending.contains(other))
    }

    func testFailedReconciliationPreservesPreviousPersistence() async throws {
        let context = try Context(); defer { context.cleanup() }
        let state = context.state(); try await state.enroll(with: "SLEEP01"); await state.requestNotificationAccess(); await state.reconcileNotifications(force: true)
        let fingerprint = state.participantState?.scheduledNotificationConfigurationFingerprint
        let date = state.participantState?.lastNotificationReconciliationDate
        context.notifications.addError = NotificationServiceError.nativeFailure("injected")
        context.notifications.clearPendingRequestsForTesting()
        await state.reconcileNotifications(force: true)
        XCTAssertEqual(state.participantState?.scheduledNotificationConfigurationFingerprint, fingerprint)
        XCTAssertEqual(state.participantState?.lastNotificationReconciliationDate, date)
    }

    func testResetCancelsOnlyActiveStudyAndClearsRuntime() async throws {
        let context = try Context(); defer { context.cleanup() }
        let other = context.request(id: "inoxity.other-study.r.1", study: "other-study"); try await context.notifications.add([other])
        let state = context.state(); try await state.enroll(with: "SLEEP01"); await state.requestNotificationAccess(); await state.reconcileNotifications(force: true)
        _ = await state.withdraw(.deleteExistingData)
        let remaining = await context.notifications.pendingRequests()
        XCTAssertEqual(remaining, [other]); XCTAssertEqual(state.notificationStatus, .notRequested)
    }

    func testRoutingWaitsForRestoreAndRejectsWrongStudy() async throws {
        let context = try Context(); defer { context.cleanup() }
        let state = context.state()
        context.notifications.simulateResponse(context.payload(study: "sleep-cognition-v2"))
        try await state.enroll(with: "SLEEP01")
        await state.applicationDidBecomeActive()
        XCTAssertEqual(state.selectedTab, .surveys); XCTAssertNil(state.focusedSurveyOccurrenceID)
        XCTAssertEqual(state.surveyErrorMessage, "The requested survey is no longer available.")
        context.notifications.simulateResponse(context.payload(study: "other")); XCTAssertEqual(state.selectedTab, .surveys)
    }

    // Regression coverage for the one item live device testing couldn't otherwise confirm without
    // waiting for or forcing a real reminder to fire: tapping a notification for a survey
    // occurrence that's actually available must open THAT specific occurrence, not just land on
    // the Surveys tab. testRoutingWaitsForRestoreAndRejectsWrongStudy above already covers the
    // rejection path (an occurrence ID that doesn't exist/isn't available); this covers the
    // happy path with a real occurrence ID pulled from the live survey summary, the same way
    // AppStateSurveyTests does for in-app survey presentation.
    func testNotificationTapOpensTheSpecificAvailableOccurrence() async throws {
        // Matches AppStateSurveyTests.Context's own date construction: a plain `Date()` (this
        // file's other default) wouldn't land inside SleepStudy's actual schedule window, so no
        // occurrence would ever be `.available` to route a tap to.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SleepStudy", withExtension: "json"))
        let sleepStudy = try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: sleepStudy.schedule.timeZone)!
        let now = calendar.date(from: .init(year: 2026, month: 7, day: 24, hour: 10))!
        let enrollment = calendar.date(from: .init(year: 2026, month: 7, day: 1))!
        let context = try Context(now: now); defer { context.cleanup() }
        // Seeds the store and restores directly, like AppStateSurveyTests.Context.restoredState(),
        // rather than going through enroll(with:) — that constructs ParticipantState with its
        // default enrollmentDate (Date(), i.e. today, not this test's fixed `now`), which would
        // enroll the participant AFTER `now` and leave no occurrence available to route to.
        try context.store.saveState(.init(studyID: sleepStudy.identity.id, enrollmentDate: enrollment, onboardingComplete: true))
        context.store.setActiveStudyCode(sleepStudy.identity.code)
        let state = context.state(); await state.restoreEnrollment()
        let occurrence = try XCTUnwrap(state.surveySummary.occurrences.first { $0.status == .available })
        context.notifications.simulateResponse([
            "studyID": state.configuration!.identity.id, "reminderID": "morning-reminder",
            "notificationKind": "survey", "surveyID": occurrence.surveyID, "occurrenceID": occurrence.id,
            "destination": "surveys",
        ])
        XCTAssertEqual(state.selectedTab, .surveys)
        XCTAssertEqual(state.focusedSurveyOccurrenceID, occurrence.id)
        XCTAssertNil(state.surveyErrorMessage)
    }

    @MainActor private final class Context {
        let suite = "AppStateNotificationTests.\(UUID())"; let defaults: UserDefaults
        let store: UserDefaultsParticipantStateStore; let notifications: MockNotificationService; let study: StudyConfiguration
        let now: Date
        // Defaults to the real current date, matching every existing test here, none of which
        // care about survey-occurrence availability — only testNotificationTapOpensThe... needs
        // a fixed date actually inside SleepStudy's schedule window (like AppStateSurveyTests'
        // Context does) so `.available` occurrences genuinely exist to route a tap to.
        init(status: NativeNotificationAuthorizationStatus = .authorized, disableNotifications: Bool = false,
             available: Bool = true, now: Date = Date()) throws {
            self.now = now
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); store = .init(defaults: defaults); notifications = .init(isAvailable: available, nativeStatus: status)
            let url = try XCTUnwrap(Bundle(for: AppStateNotificationTests.self).url(forResource: "SleepStudy", withExtension: "json")); let data = try Data(contentsOf: url)
            if disableNotifications {
                var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any]); root["notifications"] = ["enabled":false,"rationale":"Not used"]
                var reminders = root["reminders"] as! [[String:Any]]; for index in reminders.indices { reminders[index]["enabled"] = false }; root["reminders"] = reminders
                study = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
            } else { study = try JSONDecoder().decode(StudyConfiguration.self, from: data) }
        }
        func state() -> AppState { AppState(container: .init(studyConfigurationProvider: NotificationTestProvider(configuration: study), participantStateStore: store, healthKitService: MockHealthKitService(), notificationService: notifications, systemSettingsOpener: MockSettingsOpener(), currentDate: { [now] in now })) }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
        func request(id: String, study: String) -> ScheduledNotification { .init(identifier: id, fireDate: Date(timeIntervalSince1970: 1_900_000_000), title: "Inoxity", body: "Activity", payload: .init(studyID: study, reminderID: "r", notificationKind: .message, surveyID: nil, occurrenceID: "1", destination: .home)) }
        func payload(study: String) -> [String:String] { ["studyID":study,"reminderID":"morning-reminder","notificationKind":"survey","surveyID":"morning-checkin","occurrenceID":"20260725","destination":"surveys"] }
    }
}
