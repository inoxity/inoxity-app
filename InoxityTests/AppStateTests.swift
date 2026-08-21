import XCTest
@testable import Inoxity

private struct TestProvider: StudyConfigurationProviding {
    let configuration: StudyConfiguration
    func configuration(for studyCode: String) async throws -> StudyConfiguration { configuration }
}

@MainActor
final class AppStateTests: XCTestCase {
    func testEnrollmentPersistsRestoresAndResetClearsActiveStudy() async throws {
        let context = try TestContext()
        defer { context.cleanup() }
        let state = context.makeAppState()

        try await state.enroll(with: "sleep01")
        state.saveParticipantID("12345")
        state.saveOnboardingStep(2)
        state.finishOnboarding()

        XCTAssertEqual(context.store.activeStudyCode, "SLEEP01")
        XCTAssertEqual(state.participantID, "12345")
        XCTAssertTrue(state.onboardingComplete)

        let restored = context.makeAppState()
        await restored.restoreEnrollment()
        XCTAssertEqual(restored.configuration?.identity.id, context.study.identity.id)
        XCTAssertEqual(restored.participantID, "12345")
        XCTAssertEqual(restored.onboardingStep, 2)
        XCTAssertTrue(restored.onboardingComplete)

        _ = await restored.withdraw(.deleteExistingData)
        XCTAssertNil(restored.configuration)
        XCTAssertNil(restored.participantState)
        XCTAssertNil(context.store.activeStudyCode)
        XCTAssertNil(try context.store.loadState(for: context.study.identity.id))
        XCTAssertEqual(context.mediaStorage.deletedStudies, [context.study.identity.id])
    }

    func testMediaDeletionFailureAbortsResetAndPreservesEnrollment() async throws {
        let context = try TestContext(); defer { context.cleanup() }
        let state = context.makeAppState(); try await state.enroll(with: "SLEEP01")
        context.mediaStorage.deleteError = MediaRuntimeError.storageFailure
        _ = await state.withdraw(.deleteExistingData)
        XCTAssertNotNil(state.configuration)
        XCTAssertNotNil(state.participantState)
        XCTAssertEqual(context.store.activeStudyCode, "SLEEP01")
        XCTAssertNotNil(try context.store.loadState(for: context.study.identity.id))
    }

    func testLegacyEnrollmentMigratesAndRestoresOnboarding() async throws {
        let context = try TestContext()
        defer { context.cleanup() }
        context.defaults.set(" sleep01 ", forKey: UserDefaultsParticipantStateStore.Key.legacyStudyCode)
        context.defaults.set("SONA-42", forKey: UserDefaultsParticipantStateStore.Key.legacyParticipantID)
        context.defaults.set(3, forKey: UserDefaultsParticipantStateStore.Key.legacyOnboardingStep)
        context.defaults.set(true, forKey: UserDefaultsParticipantStateStore.Key.legacyOnboardingComplete)

        let state = context.makeAppState()
        await state.restoreEnrollment()

        XCTAssertEqual(state.participantID, "SONA-42")
        XCTAssertEqual(state.onboardingStep, 3)
        XCTAssertTrue(state.onboardingComplete)
        XCTAssertEqual(context.store.activeStudyCode, "SLEEP01")
        XCTAssertNil(context.defaults.object(forKey: UserDefaultsParticipantStateStore.Key.legacyStudyCode))
        XCTAssertEqual(try context.store.loadState(for: context.study.identity.id)?.studyID, context.study.identity.id)
    }

    func testCorruptActiveStateFailsSafely() async throws {
        let context = try TestContext()
        defer { context.cleanup() }
        context.store.setActiveStudyCode("SLEEP01")
        context.defaults.set(Data("not-json".utf8), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + context.study.identity.id)

        let state = context.makeAppState()
        await state.restoreEnrollment()

        XCTAssertNil(state.configuration)
        XCTAssertNil(state.participantState)
        XCTAssertEqual(state.persistenceError, .corruptData)
        XCTAssertNil(context.store.activeStudyCode)
        XCTAssertNil(context.defaults.data(forKey: UserDefaultsParticipantStateStore.Key.statePrefix + context.study.identity.id))
    }
}

@MainActor
private final class TestContext {
    let suiteName = "AppStateTests.\(UUID())"
    let defaults: UserDefaults
    let store: UserDefaultsParticipantStateStore
    let study: StudyConfiguration
    let mediaStorage = MockMediaStorage()

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = UserDefaultsParticipantStateStore(defaults: defaults)
        let url = try XCTUnwrap(Bundle(for: AppStateTests.self).url(forResource: "SleepStudy", withExtension: "json"))
        study = try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
    }

    func makeAppState() -> AppState {
        AppState(container: AppContainer(studyConfigurationProvider: TestProvider(configuration: study), participantStateStore: store, healthKitService: MockHealthKitService(), notificationService: MockNotificationService(), systemSettingsOpener: SystemSettingsOpener(), mediaRuntime: MediaRuntime(storage: mediaStorage, thumbnailGenerator: MockMediaThumbnailGenerator(data: nil))))
    }

    func cleanup() { defaults.removePersistentDomain(forName: suiteName) }
}
