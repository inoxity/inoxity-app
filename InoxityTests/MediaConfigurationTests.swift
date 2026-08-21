import XCTest
@testable import Inoxity

final class MediaConfigurationTests: XCTestCase {
    func testSchemaFiveStudiesAreVisiblyDifferentAndValid() throws {
        let sleep = try load("SleepStudy")
        let activity = try load("ActivityStudy")
        XCTAssertEqual(sleep.schemaVersion, 5)
        XCTAssertEqual(sleep.media.acceptedTypes, [.photo])
        XCTAssertEqual(activity.media.acceptedTypes, [.video])
        XCTAssertNoThrow(try StudyConfigurationValidator().validate(sleep, expectedCode: "SLEEP01"))
        XCTAssertNoThrow(try StudyConfigurationValidator().validate(activity, expectedCode: "ACTIVITY02"))
    }

    func testLegacySchemaFourMediaDecodesIntoVersionFiveShape() throws {
        let source = try data("SleepStudy")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        root["schemaVersion"] = 4
        let media = try XCTUnwrap(root.removeValue(forKey: "media") as? [String: Any])
        root["mediaUploads"] = [
            "enabled": media["enabled"]!, "instructions": media["instructions"]!,
            "photoEnabled": true, "videoEnabled": false, "maximumItems": 8,
            "maximumSizeMB": 25, "submissionCategory": "sleep-diary",
            "representedDateRequired": true
        ]
        let decoded = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(decoded.media.acceptedTypes, [.photo])
        XCTAssertEqual(decoded.media.categories.first?.id, "sleep-diary")
        XCTAssertEqual(decoded.media.maximumTotalItems, 8)
    }

    func testInvalidMediaCategoryFailsConfigurationValidation() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data("SleepStudy")) as? [String: Any])
        var media = try XCTUnwrap(root["media"] as? [String: Any])
        var categories = try XCTUnwrap(media["categories"] as? [[String: Any]])
        categories[0]["acceptedTypes"] = ["video"]
        media["categories"] = categories; root["media"] = media
        let decoded = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertThrowsError(try StudyConfigurationValidator().validate(decoded))
    }

    func testWakeTimeAnchoredScheduleRequiresSleepScheduleEnabled() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data("SleepStudy")) as? [String: Any])
        root["schemaVersion"] = 6
        var surveys = try XCTUnwrap(root["surveys"] as? [[String: Any]])
        surveys[0]["schedule"] = ["pattern": "daily", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [], "anchor": "wakeTime", "offsetMinutes": 480]
        root["surveys"] = surveys
        let decoded = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        // sleepSchedule is absent, so an anchored survey schedule must be rejected.
        XCTAssertThrowsError(try StudyConfigurationValidator().validate(decoded, expectedCode: "SLEEP01"))

        root["sleepSchedule"] = ["enabled": true, "promptTitle": "Your schedule", "wakeLabel": "Wake time", "bedLabel": "Bed time"]
        let decodedWithSleepSchedule = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertNoThrow(try StudyConfigurationValidator().validate(decodedWithSleepSchedule, expectedCode: "SLEEP01"))
    }

    func testAnchoredScheduleOffsetMustBeWithinBounds() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data("SleepStudy")) as? [String: Any])
        root["schemaVersion"] = 6
        root["sleepSchedule"] = ["enabled": true, "promptTitle": "Your schedule", "wakeLabel": "Wake time", "bedLabel": "Bed time"]
        var surveys = try XCTUnwrap(root["surveys"] as? [[String: Any]])
        surveys[0]["schedule"] = ["pattern": "daily", "date": NSNull(), "hour": 0, "minute": 0, "weekdays": [], "anchor": "bedTime", "offsetMinutes": 5000]
        root["surveys"] = surveys
        let decoded = try JSONDecoder().decode(StudyConfiguration.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertThrowsError(try StudyConfigurationValidator().validate(decoded, expectedCode: "SLEEP01"))
    }

    private func load(_ name: String) throws -> StudyConfiguration {
        try JSONDecoder().decode(StudyConfiguration.self, from: data(name))
    }
    private func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
