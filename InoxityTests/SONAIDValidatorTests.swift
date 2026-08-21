import XCTest
@testable import Inoxity

final class SONAIDValidatorTests: XCTestCase {
    private let validator = SONAIDValidator()
    func testValidOneAndSixDigitsAndLeadingZeroes() {
        XCTAssertEqual(validator.validate("1"), .valid("1"))
        XCTAssertEqual(validator.validate("123456"), .valid("123456"))
        XCTAssertEqual(validator.validate("001234"), .valid("001234"))
    }
    func testRejectsSevenDigitsLettersSymbolsWhitespaceAndMixedPaste() {
        XCTAssertEqual(validator.validate("1234567"), .tooLong)
        for value in ["ABC123", "12-34", "12 34", " 123", "123abc", "１２３"] {
            XCTAssertEqual(validator.validate(value), .containsInvalidCharacters)
        }
        XCTAssertEqual(validator.validate(""), .empty)
    }
}

private struct ParticipantIDTestProvider: StudyConfigurationProviding {
    let value: StudyConfiguration
    func configuration(for studyCode: String) async throws -> StudyConfiguration { value }
}
@MainActor private struct ParticipantIDSettingsOpener: SystemSettingsOpening { func openNotificationSettings() {}; func openHealthApp() {} }

@MainActor
final class AppStateParticipantIDTests: XCTestCase {
    func testInvalidSONABypassNeverPersistsAndValidRestores() async throws {
        let context = try Context("SleepStudy"); defer { context.cleanup() }
        let state = context.state(); try await state.enroll(with: "SLEEP01")
        for invalid in ["ABC123", "1234567", "12 34"] { XCTAssertFalse(state.saveParticipantID(invalid)) }
        XCTAssertEqual(try context.store.loadState(for: context.study.identity.id)?.externalParticipantID, "")
        XCTAssertTrue(state.saveParticipantID("001234"))
        let restored = context.state(); await restored.restoreEnrollment()
        XCTAssertEqual(restored.participantID, "001234")
    }
    func testGenericNonSONAIdentifierBehaviorIsPreserved() async throws {
        let context = try Context("ActivityStudy"); defer { context.cleanup() }
        let state = context.state(); try await state.enroll(with: "ACTIVITY02")
        XCTAssertTrue(state.saveParticipantID(" MOVE-204 "))
        XCTAssertEqual(state.participantID, "MOVE-204")
        XCTAssertFalse(state.saveParticipantID("bad value"))
        XCTAssertEqual(state.participantID, "MOVE-204")
    }
    @MainActor private final class Context {
        let name = "AppStateParticipantIDTests.\(UUID())"; let defaults: UserDefaults
        let store: UserDefaultsParticipantStateStore; let study: StudyConfiguration
        init(_ fixture: String) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: name)); store = .init(defaults: defaults)
            let url = try XCTUnwrap(Bundle(for: AppStateParticipantIDTests.self).url(forResource: fixture, withExtension: "json"))
            study = try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
        }
        func state() -> AppState { .init(container: .init(studyConfigurationProvider: ParticipantIDTestProvider(value: study), participantStateStore: store, healthKitService: MockHealthKitService(), notificationService: MockNotificationService(), systemSettingsOpener: ParticipantIDSettingsOpener())) }
        func cleanup() { defaults.removePersistentDomain(forName: name) }
    }
}
