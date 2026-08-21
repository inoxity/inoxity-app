import XCTest
@testable import Inoxity

@MainActor final class NotificationServiceTests: XCTestCase {
    func testMockPermissionPendingAddRemoveAndStudyCancellation() async throws {
        let service = MockNotificationService(nativeStatus: .authorized)
        let status = await service.authorizationStatus()
        let permission = try await service.requestAuthorization()
        XCTAssertEqual(status, .authorized); XCTAssertEqual(permission, .completed)
        let a = request("inoxity.a.r.1", study: "a"), b = request("inoxity.b.r.1", study: "b")
        try await service.add([a,b]); let before = await service.pendingRequests(); XCTAssertEqual(before.count, 2)
        await service.removePendingRequests(forStudyID: "a")
        let after = await service.pendingRequests(); XCTAssertEqual(after, [b])
    }
    private func request(_ id: String, study: String) -> ScheduledNotification {
        .init(identifier: id, fireDate: Date(timeIntervalSince1970: 100), title: "Inoxity", body: "Activity available.", payload: .init(studyID: study, reminderID: "r", notificationKind: .message, surveyID: nil, occurrenceID: "1", destination: .home))
    }
}
