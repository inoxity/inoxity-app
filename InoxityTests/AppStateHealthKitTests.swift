import XCTest
@testable import Inoxity

private struct HealthKitTestProvider: StudyConfigurationProviding {
    let configuration: StudyConfiguration
    func configuration(for studyCode: String) async throws -> StudyConfiguration { configuration }
}

@MainActor
final class AppStateHealthKitTests: XCTestCase {
    func testSleepAndActivityRequestOnlyConfiguredReadSets() async throws {
        for (fixture, expected) in [
            ("SleepStudy", Set(["sleepAnalysis", "restingHeartRate"])),
            ("ActivityStudy", Set(["stepCount", "activeEnergyBurned", "appleExerciseTime"]))
        ] {
            let context = try HealthKitTestContext(study: fixture)
            defer { context.cleanup() }
            let state = context.makeState()
            try await state.enroll(with: context.study.identity.code)
            await state.requestHealthKitAccess()
            XCTAssertEqual(context.healthKit.authorizationRequests, [expected])
            // Neither fixture opts into HealthKitConfiguration.includeCharacteristics — this is
            // the regression check for participants being prompted for biological sex/blood
            // type/date of birth/skin type/wheelchair use despite never selecting them.
            XCTAssertEqual(context.healthKit.includeCharacteristicsRequests, [false, false])
            XCTAssertEqual(state.participantState?.healthKitRequestState, .requestCompleted)
        }
    }

    func testCharacteristicsNotRequestedOrReadWhenStudyDoesNotOptIn() async throws {
        let context = try HealthKitTestContext(study: "SleepStudy")
        defer { context.cleanup() }
        context.healthKit.characteristicsResult = HealthKitCharacteristics(biologicalSex: "female")
        let state = context.makeState()
        try await state.enroll(with: "SLEEP01")
        await state.requestHealthKitAccess()
        XCTAssertEqual(context.healthKit.includeCharacteristicsRequests, [false, false])
        XCTAssertEqual(context.healthKit.characteristicsReadCount, 0)
        XCTAssertNil(state.participantState?.healthKitCharacteristics)
    }

    func testHealthKitDisabledDoesNotRequestOrQuery() async throws {
        let context = try HealthKitTestContext(study: "SleepStudy", healthKitDisabled: true)
        defer { context.cleanup() }
        let state = context.makeState()
        try await state.enroll(with: "SLEEP01")
        await state.requestHealthKitAccess()
        await state.syncHealthKitNow()
        XCTAssertTrue(context.healthKit.authorizationRequests.isEmpty)
        XCTAssertTrue(context.healthKit.syncRequests.isEmpty)
        XCTAssertEqual(state.participantState?.healthKitRequestState, .notRequested)
    }

    func testUnavailableHealthKitDoesNotRequestAndReportsUnavailable() async throws {
        let context = try HealthKitTestContext(study: "SleepStudy", available: false)
        defer { context.cleanup() }
        let state = context.makeState()
        try await state.enroll(with: "SLEEP01")
        await state.requestHealthKitAccess()
        XCTAssertTrue(context.healthKit.authorizationRequests.isEmpty)
        XCTAssertEqual(state.healthKitStatus, .unavailable)
    }

    func testSuccessfulRequestPersistsCharacteristicsSnapshotWhenOptedIn() async throws {
        let context = try HealthKitTestContext(study: "SleepStudy", includeCharacteristics: true)
        defer { context.cleanup() }
        context.healthKit.characteristicsResult = HealthKitCharacteristics(
            biologicalSex: "female", bloodType: "oPositive",
            dateOfBirth: Date(timeIntervalSince1970: 0), fitzpatrickSkinType: "III", usesWheelchair: false
        )
        let state = context.makeState()
        try await state.enroll(with: "SLEEP01")
        await state.requestHealthKitAccess()
        XCTAssertEqual(context.healthKit.includeCharacteristicsRequests, [true, true])
        XCTAssertEqual(context.healthKit.characteristicsReadCount, 1)
        XCTAssertEqual(state.participantState?.healthKitCharacteristics, context.healthKit.characteristicsResult)
        XCTAssertEqual(try context.store.loadState(for: context.study.identity.id)?.healthKitCharacteristics, context.healthKit.characteristicsResult)
    }

    func testAttentionResultPersistsWithoutBlockingState() async throws {
        let context = try HealthKitTestContext(study: "SleepStudy")
        defer { context.cleanup() }
        context.healthKit.authorizationResult = .success(.attentionNeeded("Access was incomplete."))
        let state = context.makeState()
        try await state.enroll(with: "SLEEP01")
        await state.requestHealthKitAccess()
        XCTAssertEqual(state.participantState?.healthKitRequestState, .attentionNeeded)
        XCTAssertEqual(state.healthKitStatus, .attentionNeeded("Access was incomplete."))
    }

    func testSuccessfulManualSyncPersistsCompletionDate() async throws {
        let date = Date(timeIntervalSince1970: 1_710_000_000)
        let summary = HealthKitLocalSyncSummary(completedAt: date, metrics: [.init(identifier: "sleepAnalysis", label: "Sleep", value: "2 samples")])
        let context = try HealthKitTestContext(study: "SleepStudy")
        defer { context.cleanup() }
        context.healthKit.syncResult = .success(summary)
        let state = context.makeState()
        try await state.enroll(with: "SLEEP01")
        await state.requestHealthKitAccess()
        await state.syncHealthKitNow()
        XCTAssertEqual(state.participantState?.lastLocalSyncDate, date)
        XCTAssertEqual(try context.store.loadState(for: context.study.identity.id)?.lastLocalSyncDate, date)
        XCTAssertEqual(state.healthKitStatus, .syncSucceeded(summary))
    }

    func testFailedSyncDoesNotUpdateLastSuccessfulDate() async throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let context = try HealthKitTestContext(study: "SleepStudy")
        defer { context.cleanup() }
        let state = context.makeState()
        try await state.enroll(with: "SLEEP01")
        await state.requestHealthKitAccess()
        context.healthKit.syncResult = .success(.init(completedAt: oldDate, metrics: []))
        await state.syncHealthKitNow()
        context.healthKit.syncResult = .failure(HealthKitServiceError.queryFailed("Injected failure"))
        await state.syncHealthKitNow()
        XCTAssertEqual(state.participantState?.lastLocalSyncDate, oldDate)
        if case .syncFailed = state.healthKitStatus {} else { XCTFail("Expected sync failure") }
    }

    func testStateIsolationAndResetClearsHealthKitRuntimeState() async throws {
        let context = try HealthKitTestContext(study: "SleepStudy")
        defer { context.cleanup() }
        let other = ParticipantState(
            studyID: "activity-study",
            enrollmentDate: Date(timeIntervalSince1970: 1_700_000_000),
            healthKitRequestState: .requestCompleted,
            lastLocalSyncDate: Date(timeIntervalSince1970: 100)
        )
        try context.store.saveState(other)
        let state = context.makeState()
        try await state.enroll(with: "SLEEP01")
        await state.requestHealthKitAccess()
        _ = await state.withdraw(.deleteExistingData)
        XCTAssertEqual(state.healthKitStatus, .notRequested)
        XCTAssertNil(try context.store.loadState(for: context.study.identity.id))
        XCTAssertEqual(try context.store.loadState(for: "activity-study"), other)
    }
}

@MainActor
private final class HealthKitTestContext {
    let suite = "AppStateHealthKitTests.\(UUID())"
    let defaults: UserDefaults
    let store: UserDefaultsParticipantStateStore
    let healthKit: MockHealthKitService
    let study: StudyConfiguration

    init(study name: String, healthKitDisabled: Bool = false, available: Bool = true, includeCharacteristics: Bool = false) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = UserDefaultsParticipantStateStore(defaults: defaults)
        healthKit = MockHealthKitService(isHealthDataAvailable: available)
        let url = try XCTUnwrap(Bundle(for: AppStateHealthKitTests.self).url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        if healthKitDisabled || includeCharacteristics {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var health = try XCTUnwrap(root["healthKit"] as? [String: Any])
            if healthKitDisabled { health["enabled"] = false; health["identifiers"] = [] }
            if includeCharacteristics { health["includeCharacteristics"] = true }
            root["healthKit"] = health
            self.study = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        } else {
            self.study = try JSONDecoder().decode(StudyConfiguration.self, from: data)
        }
    }

    func makeState() -> AppState {
        AppState(container: .init(studyConfigurationProvider: HealthKitTestProvider(configuration: study), participantStateStore: store, healthKitService: healthKit, notificationService: MockNotificationService(), systemSettingsOpener: SystemSettingsOpener()))
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}
