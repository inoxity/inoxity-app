import XCTest
@testable import Inoxity

@MainActor
final class ParticipantStatePhase3MigrationTests: XCTestCase {
    func testVersionFiveMigratesToSixPreservingAllExistingState() throws {
        try withContext { store, _, defaults in
            var value = ParticipantState(persistenceVersion: 5, studyID: "study", externalParticipantID: "001234",
                healthKitRequestState: .requestCompleted, notificationPermissionState: .requestCompleted)
            value.scheduledNotificationIdentifiers = ["notification"]
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
            object.removeValue(forKey: "withdrawalChoice"); object.removeValue(forKey: "withdrawalRequestedAt")
            object.removeValue(forKey: "lastNotificationReconciliationResult")
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "study")
            let migrated = try XCTUnwrap(store.loadState(for: "study"))
            XCTAssertEqual(migrated.persistenceVersion, ParticipantState.currentPersistenceVersion); XCTAssertEqual(migrated.externalParticipantID, "001234")
            XCTAssertEqual(migrated.healthKitRequestState, .requestCompleted); XCTAssertEqual(migrated.notificationPermissionState, .requestCompleted)
            XCTAssertEqual(migrated.scheduledNotificationIdentifiers, ["notification"])
            XCTAssertNil(migrated.withdrawalChoice); XCTAssertNil(migrated.withdrawalRequestedAt)
        }
    }

    func testFutureAndCorruptStateFailWithoutMutation() throws {
        try withContext { store, _, defaults in
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let future = try encoder.encode(ParticipantState(persistenceVersion: 99, studyID: "future"))
            defaults.set(future, forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "future")
            XCTAssertThrowsError(try store.loadState(for: "future")); XCTAssertEqual(defaults.data(forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "future"), future)
            let corrupt = Data("bad".utf8); defaults.set(corrupt, forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "corrupt")
            XCTAssertThrowsError(try store.loadState(for: "corrupt")); XCTAssertEqual(defaults.data(forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "corrupt"), corrupt)
        }
    }

    func testPendingWithdrawalEventsRestoreByStudy() throws {
        try withContext { _, events, _ in
            let event = PendingWithdrawalEvent(id: "abc", studyID: "sleep", choice: .deleteExistingData,
                requestedAt: Date(timeIntervalSince1970: 100), syncStatus: .pending)
            try events.save(event)
            XCTAssertEqual(try events.events(for: "sleep"), [event]); XCTAssertTrue(try events.events(for: "activity").isEmpty)
        }
    }

    private func withContext(_ body: (UserDefaultsParticipantStateStore, UserDefaultsWithdrawalEventStore, UserDefaults) throws -> Void) throws {
        let name = "ParticipantStatePhase3MigrationTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        try body(.init(defaults: defaults), .init(defaults: defaults), defaults)
    }
}
