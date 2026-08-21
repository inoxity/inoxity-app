import XCTest
@testable import Inoxity

@MainActor
final class ParticipantStateStoreTests: XCTestCase {
    func testPersistenceRoundTrip() throws {
        try withStore { store, _ in
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let state = ParticipantState(participantUUID: UUID(), studyID: "sleep-study", externalParticipantID: "42", enrollmentDate: date, onboardingStep: 2, onboardingComplete: true)
            try store.saveState(state)
            XCTAssertEqual(try store.loadState(for: "sleep-study"), state)
        }
    }

    func testStudyIsolationAndTargetedRemoval() throws {
        try withStore { store, _ in
            let enrollmentDate = Date(timeIntervalSince1970: 1_700_000_000)
            let sleep = ParticipantState(studyID: "sleep-study", externalParticipantID: "S1", enrollmentDate: enrollmentDate)
            let activity = ParticipantState(studyID: "activity-study", externalParticipantID: "A1", enrollmentDate: enrollmentDate)
            try store.saveState(sleep)
            try store.saveState(activity)
            store.removeState(for: "sleep-study")
            XCTAssertNil(try store.loadState(for: "sleep-study"))
            XCTAssertEqual(try store.loadState(for: "activity-study"), activity)
        }
    }

    func testCorruptDataThrowsTypedError() throws {
        try withStore { store, defaults in
            defaults.set(Data([0xFF, 0x00]), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "sleep-study")
            XCTAssertThrowsError(try store.loadState(for: "sleep-study")) { error in
                XCTAssertEqual(error as? ParticipantStatePersistenceError, .corruptData)
            }
        }
    }

    func testUnsupportedVersionThrowsTypedError() throws {
        try withStore { store, defaults in
            let unsupported = ParticipantState(persistenceVersion: 99, studyID: "sleep-study")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            defaults.set(try encoder.encode(unsupported), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "sleep-study")
            XCTAssertThrowsError(try store.loadState(for: "sleep-study")) { error in
                XCTAssertEqual(error as? ParticipantStatePersistenceError, .unsupportedVersion(99))
            }
        }
    }

    func testVersionOneMigratesToCurrentWithHealthNotificationSurveyAndMediaDefaults() throws {
        try withStore { store, defaults in
            let legacy = ParticipantState(persistenceVersion: 1, studyID: "sleep-study", externalParticipantID: "S1")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
            object.removeValue(forKey: "healthKitRequestState")
            object.removeValue(forKey: "lastLocalSyncDate")
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "sleep-study")

            let migrated = try XCTUnwrap(store.loadState(for: "sleep-study"))
            XCTAssertEqual(migrated.persistenceVersion, ParticipantState.currentPersistenceVersion)
            XCTAssertEqual(migrated.healthKitRequestState, .notRequested)
            XCTAssertNil(migrated.lastLocalSyncDate)
            XCTAssertEqual(migrated.notificationPermissionState, .notRequested)
            XCTAssertNil(migrated.lastNotificationReconciliationDate)
            XCTAssertTrue(migrated.scheduledNotificationIdentifiers.isEmpty)
            XCTAssertTrue(migrated.mediaDrafts.isEmpty)
            XCTAssertEqual(try store.loadState(for: "sleep-study")?.persistenceVersion, ParticipantState.currentPersistenceVersion)
        }
    }

    func testVersionTwoMigratesToCurrentWithNotificationAndMediaDefaults() throws {
        try withStore { store, defaults in
            let versionTwo = ParticipantState(persistenceVersion: 2, studyID: "sleep-study", healthKitRequestState: .requestCompleted)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(versionTwo)) as? [String: Any])
            ["notificationPermissionState", "lastNotificationReconciliationDate", "scheduledNotificationConfigurationFingerprint", "scheduledNotificationIdentifiers"].forEach { object.removeValue(forKey: $0) }
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "sleep-study")
            let migrated = try XCTUnwrap(store.loadState(for: "sleep-study"))
            XCTAssertEqual(migrated.persistenceVersion, ParticipantState.currentPersistenceVersion)
            XCTAssertEqual(migrated.healthKitRequestState, .requestCompleted)
            XCTAssertEqual(migrated.notificationPermissionState, .notRequested)
            XCTAssertTrue(migrated.scheduledNotificationIdentifiers.isEmpty)
            XCTAssertTrue(migrated.mediaDrafts.isEmpty)
        }
    }

    func testLegacyValuesAreReadWithoutAffectingOtherStudyState() throws {
        try withStore { store, defaults in
            let activity = ParticipantState(
                studyID: "activity-study",
                externalParticipantID: "A1",
                enrollmentDate: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try store.saveState(activity)
            defaults.set("sleep01", forKey: UserDefaultsParticipantStateStore.Key.legacyStudyCode)
            defaults.set("S1", forKey: UserDefaultsParticipantStateStore.Key.legacyParticipantID)
            XCTAssertEqual(store.legacyEnrollment()?.studyCode, "SLEEP01")
            store.clearLegacyEnrollment()
            XCTAssertEqual(try store.loadState(for: "activity-study"), activity)
        }
    }

    private func withStore(_ body: (UserDefaultsParticipantStateStore, UserDefaults) throws -> Void) throws {
        let suite = "ParticipantStateStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(UserDefaultsParticipantStateStore(defaults: defaults), defaults)
    }
}
