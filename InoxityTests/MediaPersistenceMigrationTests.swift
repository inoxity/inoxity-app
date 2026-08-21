import XCTest
@testable import Inoxity

@MainActor
final class MediaPersistenceMigrationTests: XCTestCase {
    func testVersionFourMigratesToFiveWithEmptyMediaState() throws {
        try withStore { store, defaults in
            let old = ParticipantState(persistenceVersion: 4, studyID: "sleep-study")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
            object.removeValue(forKey: "mediaDrafts")
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: UserDefaultsParticipantStateStore.Key.statePrefix + "sleep-study")
            let result = try XCTUnwrap(store.loadState(for: "sleep-study"))
            XCTAssertEqual(result.persistenceVersion, ParticipantState.currentPersistenceVersion)
            XCTAssertTrue(result.mediaDrafts.isEmpty)
        }
    }

    func testMediaStateRoundTripAndStudyIsolation() throws {
        try withStore { store, _ in
            var sleep = ParticipantState(studyID: "sleep-study")
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            let draft = PersistedMediaDraft(id: "draft", studyID: "sleep-study", categoryID: "sleep", mediaType: .photo,
                createdAt: timestamp, lastModifiedAt: timestamp, originalFilenameExtension: "jpg", relativeMediaPath: "original.jpg",
                relativeThumbnailPath: nil, byteCount: 1, durationSeconds: nil, uniformTypeIdentifier: "public.jpeg",
                mimeType: "image/jpeg", sha256: "hash", representedDate: nil, status: .ready, failureReason: nil)
            sleep.mediaDrafts[draft.id] = draft
            try store.saveState(sleep); try store.saveState(ParticipantState(studyID: "activity-study"))
            XCTAssertEqual(try store.loadState(for: "sleep-study")?.mediaDrafts[draft.id], draft)
            XCTAssertTrue(try XCTUnwrap(store.loadState(for: "activity-study")).mediaDrafts.isEmpty)
        }
    }
    private func withStore(_ body: (UserDefaultsParticipantStateStore, UserDefaults) throws -> Void) throws {
        let name = "MediaPersistenceMigrationTests.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(UserDefaultsParticipantStateStore(defaults: defaults), defaults)
    }
}
