import XCTest
@testable import Inoxity

@MainActor final class SurveyPersistenceMigrationTests: XCTestCase {
    func testVersionThreeMigratesToCurrentWithEmptySurveyState() throws {
        let name = "SurveyMigration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let state = ParticipantState(persistenceVersion: 3, studyID: "study")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String:Any])
        object.removeValue(forKey: "surveyOccurrenceStates")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "study")
        let migrated = try XCTUnwrap(UserDefaultsParticipantStateStore(defaults: defaults).loadState(for: "study"))
        XCTAssertEqual(migrated.persistenceVersion, ParticipantState.currentPersistenceVersion); XCTAssertTrue(migrated.surveyOccurrenceStates.isEmpty)
    }

    func testSurveyStateRoundTripsAndIsStudyScoped() throws {
        let name = "SurveyRoundTrip.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsParticipantStateStore(defaults: defaults), date = Date(timeIntervalSince1970: 1_800_000_000)
        var a = ParticipantState(studyID: "a"); a.surveyOccurrenceStates["inoxity.a.q.20270115T0900"] = .init(occurrenceID: "inoxity.a.q.20270115T0900", surveyID: "q", scheduledFor: date, openedAt: date, completedAt: date)
        let b = ParticipantState(studyID: "b"); try store.saveState(a); try store.saveState(b)
        XCTAssertEqual(try store.loadState(for: "a")?.surveyOccurrenceStates.count, 1); XCTAssertTrue(try XCTUnwrap(store.loadState(for: "b")).surveyOccurrenceStates.isEmpty)
    }
}
