import HealthKit
import XCTest
@testable import Inoxity

final class HealthKitTypeRegistryTests: XCTestCase {
    // The original ten — kept as an explicit regression check (table names, units, and behavior
    // for these must never change silently) rather than asserting the full ~115-identifier
    // catalog exactly, which would need editing on every future addition for no real benefit.
    private let originalTen: Set<String> = [
        "sleepAnalysis", "stepCount", "restingHeartRate", "heartRate",
        "heartRateVariabilitySDNN", "activeEnergyBurned", "appleExerciseTime",
        "respiratoryRate", "timeInDaylight", "workout"
    ]

    func testOriginalTenStillSupported() throws {
        XCTAssertTrue(originalTen.isSubset(of: HealthKitTypeRegistry.supportedIdentifiers))
    }

    func testEverySupportedIdentifierMapsToNativeTypeAndReadableMetadata() throws {
        for identifier in HealthKitTypeRegistry.supportedIdentifiers {
            let metadata = try HealthKitTypeRegistry.type(for: identifier)
            XCTAssertEqual(metadata.identifier, identifier)
            XCTAssertFalse(metadata.displayLabel.isEmpty, "\(identifier) has an empty displayLabel")
            XCTAssertFalse(metadata.symbol.isEmpty, "\(identifier) has an empty symbol")
            XCTAssertFalse(metadata.tableName.isEmpty, "\(identifier) has an empty tableName")
            XCTAssertNotNil(metadata.objectType)
            // Quantity/correlation types must carry a canonicalUploadUnit (used for both storage
            // validation and local-summary display); category/workout types deliberately don't.
            if metadata.sampleKind == .quantity {
                XCTAssertNotNil(metadata.unit, "\(identifier) is .quantity but has no HKUnit")
                XCTAssertNotNil(metadata.canonicalUploadUnit, "\(identifier) is .quantity but has no canonicalUploadUnit")
            }
        }
    }

    func testNoDuplicateTableNames() {
        let tableNames = HealthKitTypeRegistry.supportedIdentifiers.compactMap { try? HealthKitTypeRegistry.type(for: $0).tableName }
        XCTAssertEqual(tableNames.count, Set(tableNames).count, "Two or more identifiers share the same tableName")
    }

    func testUnsupportedIdentifierThrowsClearError() {
        XCTAssertThrowsError(try HealthKitTypeRegistry.type(for: "bloodMagic")) { error in
            XCTAssertEqual(error as? HealthKitServiceError, .unsupportedIdentifier("bloodMagic"))
        }
    }

    func testConfiguredReadSetsForBundledStudies() throws {
        let sleep = try fixture("SleepStudy")
        let activity = try fixture("ActivityStudy")
        XCTAssertEqual(Set(sleep.healthKit.identifiers), ["sleepAnalysis", "restingHeartRate"])
        XCTAssertEqual(Set(activity.healthKit.identifiers), ["stepCount", "activeEnergyBurned", "appleExerciseTime"])
        XCTAssertNoThrow(try HealthKitTypeRegistry.types(for: Set(sleep.healthKit.identifiers)))
        XCTAssertNoThrow(try HealthKitTypeRegistry.types(for: Set(activity.healthKit.identifiers)))
    }

    private func fixture(_ name: String) throws -> StudyConfiguration {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
    }
}
