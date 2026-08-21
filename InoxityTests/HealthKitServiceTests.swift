import XCTest
@testable import Inoxity

@MainActor
final class HealthKitServiceTests: XCTestCase {
    func testMockAuthorizationSuccessAndRecordedSet() async throws {
        let service = MockHealthKitService(authorizationResult: .success(.completed))
        let identifiers: Set<String> = ["sleepAnalysis", "restingHeartRate"]
        let result = try await service.requestReadAuthorization(for: identifiers)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(service.authorizationRequests, [identifiers])
    }

    func testMockPartialOrDeniedResultUsesAttentionNeeded() async throws {
        let service = MockHealthKitService(authorizationResult: .success(.attentionNeeded("Some access was not completed.")))
        let result = try await service.requestReadAuthorization(for: ["stepCount"])
        XCTAssertEqual(result, .attentionNeeded("Some access was not completed."))
    }
}
