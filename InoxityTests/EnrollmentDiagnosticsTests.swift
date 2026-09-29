import XCTest
@testable import Inoxity

final class EnrollmentDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func code(_ error: Error, _ notes: [EnrollmentFailureNote] = []) -> String {
        EnrollmentErrorReport.make(from: error, notes: notes, at: now).code
    }
    private func note(_ stage: EnrollmentStage, _ detail: String, urlCode: Int? = nil) -> EnrollmentFailureNote {
        .init(stage: stage, detail: detail, urlErrorCode: urlCode)
    }

    func testOfflineWinsOverWhereItHappened() {
        let offline = note(.studyDatabaseSignIn, "offline", urlCode: URLError.notConnectedToInternet.rawValue)
        XCTAssertEqual(code(BackendError.unavailable, [offline]), "E01")
        XCTAssertEqual(code(URLError(.networkConnectionLost)), "E01")
    }

    func testUnreachableIsSplitByWhichServerWasBeingContacted() {
        XCTAssertEqual(code(RemoteStudyError.unavailable, [note(.inoxitySignIn, "No response within 12 seconds")]), "E02")
        XCTAssertEqual(code(RemoteStudyError.unavailable, [note(.studyLookup, "HTTP 502")]), "E02")
        // A paused study project: signing in to it times out or is refused.
        XCTAssertEqual(code(BackendError.unavailable, [note(.studyDatabaseSignIn, "No response within 12 seconds")]), "E10")
        XCTAssertEqual(code(BackendError.unavailable, [note(.registration, "No response within 20 seconds")]), "E10")
    }

    func testStudyDatabaseSetupProblemsAreRecognizedFromTheServersOwnMessage() {
        XCTAssertEqual(code(BackendError.unavailable, [note(.studyDatabaseSignIn, "AuthError: Anonymous sign-ins are disabled")]), "E11")
        // The same message from the Inoxity (control) project points somewhere else entirely.
        XCTAssertEqual(code(RemoteStudyError.unavailable, [note(.inoxitySignIn, "AuthError: Anonymous sign-ins are disabled")]), "E07")
        XCTAssertEqual(code(BackendError.unavailable, [note(.studyDatabaseCheck,
            "PostgrestError(code: PGRST202, message: Could not find the function public.get_study_backend_identity without parameters in the schema cache)")]), "E12")
        XCTAssertEqual(code(BackendError.invalidResponse, [note(.studyDatabaseCheck, EnrollmentErrorReport.identityRowMissing)]), "E12")
    }

    func testSpecificErrorsMapToTheirOwnCodes() {
        XCTAssertEqual(code(RemoteStudyError.notFound), "E03")
        XCTAssertEqual(code(RemoteStudyError.enrollmentClosed), "E06")
        XCTAssertEqual(code(BackendError.backendIdentityMismatch), "E13")
        XCTAssertEqual(code(BackendError.crossEnvironmentDescriptor), "E14")
        XCTAssertEqual(code(BackendError.inactiveBackend), "E15")
        XCTAssertEqual(code(BackendError.withdrawnEnrollment), "E16")
        XCTAssertEqual(code(RemoteStudyError.unsupportedConfiguration), "E20")
        XCTAssertEqual(code(RemoteStudyError.invalidConfiguration, [note(.studyLookup, "study_backend_unavailable")]), "E22")
        XCTAssertEqual(code(RemoteStudyError.invalidConfiguration), "E21")
        XCTAssertEqual(code(BackendError.malformedURL), "E23")
    }

    func testAResearchersStatusMessageReachesTheParticipant() {
        let paused = StudyConfigurationError.unavailable(.paused, message: "We're paused for the holidays.")
        let report = EnrollmentErrorReport.make(from: paused, notes: [], at: now)
        XCTAssertEqual(report.code, "E04")
        XCTAssertEqual(report.message, "We're paused for the holidays.")
    }

    func testMessagesTellParticipantsWhichCodeToMention() {
        let report = EnrollmentErrorReport.make(from: BackendError.inactiveBackend, notes: [], at: now)
        XCTAssertTrue(report.message.contains("mention code E15"))
    }

    func testCopiedDetailsNameTheStepAndNeverIncludeCredentials() {
        let leaky = note(.studyDatabaseCheck, "request failed apikey=abc123 Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig")
        let report = EnrollmentErrorReport.make(from: BackendError.unavailable, notes: [leaky], at: now)
        let text = report.copyText(studyCode: "SLEEP01", appVersion: "1.0 (3)", environment: "Production")
        XCTAssertTrue(text.contains("Inoxity error E10"))
        XCTAssertTrue(text.contains("Step: Checking the study database"))
        XCTAssertTrue(text.contains("Study code: SLEEP01"))
        XCTAssertFalse(text.contains("abc123"))
        XCTAssertFalse(text.contains("eyJhbGciOiJIUzI1NiJ9"))
    }

    func testRecorderOnlyCollectsInsideItsOwnTask() async {
        EnrollmentDiagnostics.record(detail: "outside", stage: .studyLookup)   // no recorder: ignored
        let recorder = EnrollmentDiagnosticsRecorder()
        await EnrollmentDiagnostics.$recorder.withValue(recorder) {
            EnrollmentDiagnostics.record(detail: "inside", stage: .registration)
            await Task { EnrollmentDiagnostics.record(detail: "child task", stage: .registration) }.value
        }
        XCTAssertEqual(recorder.notes.map(\.detail), ["inside", "child task"])
    }
}
