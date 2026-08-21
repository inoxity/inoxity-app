import XCTest
@testable import Inoxity

private struct TestProvider: StudyConfigurationProviding {
    let configuration: StudyConfiguration
    func configuration(for studyCode: String) async throws -> StudyConfiguration { configuration }
}

// Minimal stand-ins for the StudyBackendContext fields uploadMediaDraft doesn't exercise —
// mirrors Phase3BFoundationTests.swift's NoopStudyServices pattern (each test file defines its
// own small fakes; there's no shared cross-file test-support module in this codebase).
private actor NoopStudyServices: StudyBackendAuthenticating, RemoteEnrollmentRepository, RemoteWithdrawalRepository, SurveyEventUploadRepository {
    let backendID: UUID; let storageNamespace: String
    init(backendID: UUID, namespace: String) { self.backendID = backendID; storageNamespace = namespace }
    func authenticatedParticipant() async throws -> AuthenticatedParticipant { .init(authUserID: UUID(), isAnonymous: true, createdAt: nil) }
    func ensureParticipant() async throws -> RemoteParticipant { .init(id: UUID(), createdAt: Date()) }
    func register(_ registration: EnrollmentRegistration) async throws -> RemoteEnrollment { throw BackendError.unavailable }
    func updateSleepSchedule(wakeMinutes: Int, bedMinutes: Int) async throws { throw BackendError.unavailable }
    func updateParticipantIdentifier(_ value: String) async throws { throw BackendError.unavailable }
    func updateParticipantCharacteristics(_ value: HealthKitCharacteristics) async throws { throw BackendError.unavailable }
    func submit(_ event: PendingWithdrawalEvent, remoteEnrollmentID: UUID?) async throws -> UUID { throw BackendError.unavailable }
    func upload(_ event: SurveyEventUpload) async throws -> SurveyEventAcknowledgment { throw BackendError.unavailable }
}

private actor FakeMediaUploadRepository: MediaUploadRepository {
    private var result: Result<MediaUploadAcknowledgment, Error>
    private(set) var uploadedDescriptors: [MediaUploadDescriptor] = []
    init(result: Result<MediaUploadAcknowledgment, Error>) { self.result = result }
    func setResult(_ value: Result<MediaUploadAcknowledgment, Error>) { result = value }
    func upload(_ media: MediaUploadDescriptor, data: Data) async throws -> MediaUploadAcknowledgment {
        uploadedDescriptors.append(media); return try result.get()
    }
}

private struct FakeStudyBackendRouting: StudyBackendRouting {
    let context: StudyBackendContext
    func context(for state: ParticipantState) async throws -> StudyBackendContext { context }
    func context(for event: PendingWithdrawalEvent) async throws -> StudyBackendContext { context }
    func context(for event: SurveyEventUpload) async throws -> StudyBackendContext { context }
}

@MainActor
final class AppStateMediaUploadTests: XCTestCase {
    func testSuccessfulUploadDeletesLocalDraftAndClearsMediaSummary() async throws {
        let context = try TestContext()
        defer { context.cleanup() }
        let ack = MediaUploadAcknowledgment(id: UUID(), receivedAt: Date())
        await context.mediaRepository.setResult(.success(ack))
        let state = try await context.makeRegisteredAppState()

        await state.uploadMediaDraft(context.draft.id)

        XCTAssertNil(state.participantState?.mediaDrafts[context.draft.id])
        XCTAssertTrue(state.mediaSummary.drafts.isEmpty)
        XCTAssertNil(state.mediaErrorMessage)
        XCTAssertNotNil(state.mediaUploadSuccessMessage)
        XCTAssertTrue(context.mediaStorage.deleted.contains(context.draft.id))
        let uploaded = await context.mediaRepository.uploadedDescriptors
        XCTAssertEqual(uploaded.first?.draftID, context.draft.id)
        XCTAssertEqual(uploaded.first?.remoteEnrollmentID, context.remoteEnrollmentID)
    }

    func testFailedUploadSetsUploadFailedAndKeepsDraftForRetry() async throws {
        let context = try TestContext()
        defer { context.cleanup() }
        await context.mediaRepository.setResult(.failure(BackendError.unavailable))
        let state = try await context.makeRegisteredAppState()

        await state.uploadMediaDraft(context.draft.id)

        XCTAssertEqual(state.participantState?.mediaDrafts[context.draft.id]?.status, .uploadFailed)
        XCTAssertNotNil(state.mediaErrorMessage)
        XCTAssertFalse(context.mediaStorage.deleted.contains(context.draft.id))
    }

    func testRetryAfterFailureCanSucceed() async throws {
        let context = try TestContext()
        defer { context.cleanup() }
        await context.mediaRepository.setResult(.failure(BackendError.unavailable))
        let state = try await context.makeRegisteredAppState()
        await state.uploadMediaDraft(context.draft.id)
        XCTAssertEqual(state.participantState?.mediaDrafts[context.draft.id]?.status, .uploadFailed)

        let ack = MediaUploadAcknowledgment(id: UUID(), receivedAt: Date())
        await context.mediaRepository.setResult(.success(ack))
        await state.uploadMediaDraft(context.draft.id)

        XCTAssertNil(state.participantState?.mediaDrafts[context.draft.id])
        XCTAssertNil(state.mediaErrorMessage)
    }

    func testUploadWithoutARouterFailsGracefullyAndKeepsDraft() async throws {
        let context = try TestContext()
        defer { context.cleanup() }
        let state = try await context.makeRegisteredAppState(includeRouter: false)

        await state.uploadMediaDraft(context.draft.id)

        XCTAssertEqual(state.participantState?.mediaDrafts[context.draft.id]?.status, .ready)
        XCTAssertNotNil(state.mediaErrorMessage)
    }
}

@MainActor
private final class TestContext {
    let suiteName = "AppStateMediaUploadTests.\(UUID())"
    let defaults: UserDefaults
    let store: UserDefaultsParticipantStateStore
    let study: StudyConfiguration
    let mediaStorage = MockMediaStorage()
    let mediaRepository: FakeMediaUploadRepository
    let backendID = UUID()
    let remoteEnrollmentID = UUID()
    let draft: PersistedMediaDraft
    // MockMediaStorage.mediaURL(studyID:draftID:relativePath:) hardcodes "/tmp/<draftID>/<relativePath>"
    // regardless of studyID — uploadMediaDraft reads real bytes from that URL via
    // Data(contentsOf:), so a real file must exist there for the upload path to succeed.
    private let fileURL: URL

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = UserDefaultsParticipantStateStore(defaults: defaults)
        let url = try XCTUnwrap(Bundle(for: AppStateMediaUploadTests.self).url(forResource: "SleepStudy", withExtension: "json"))
        study = try JSONDecoder().decode(StudyConfiguration.self, from: Data(contentsOf: url))
        mediaRepository = FakeMediaUploadRepository(result: .failure(BackendError.unavailable))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        draft = PersistedMediaDraft(id: "draft-1", studyID: study.identity.id, categoryID: "sleep-environment", mediaType: .photo,
            createdAt: timestamp, lastModifiedAt: timestamp, originalFilenameExtension: "jpg", relativeMediaPath: "original.jpg",
            relativeThumbnailPath: nil, byteCount: 5, durationSeconds: nil, uniformTypeIdentifier: "public.jpeg",
            mimeType: "image/jpeg", sha256: "hash", representedDate: Date(timeIntervalSince1970: 1_700_000_000), status: .ready, failureReason: nil)
        fileURL = URL(fileURLWithPath: "/tmp/\(draft.id)/original.jpg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: fileURL)
    }

    /// Pre-seeds a fully enrolled+registered `ParticipantState` (with `draft` already in
    /// `mediaDrafts`) directly into the store, then loads it via `restoreEnrollment()` — mirrors
    /// `AppStateTests.swift`'s pattern for injecting specific persisted state without going
    /// through the full network enrollment flow.
    func makeRegisteredAppState(includeRouter: Bool = true) async throws -> AppState {
        var participant = ParticipantState(studyID: study.identity.id, externalParticipantID: "P1",
            enrollmentSyncStatus: .registered, remoteEnrollmentID: remoteEnrollmentID,
            studyBackendID: backendID, studyBackendDescriptorCacheKey: "c1-d1.bootstrap",
            studyBackendDescriptorRevision: 1, backendRoutingStatus: .registered)
        participant.mediaDrafts[draft.id] = draft
        try store.saveState(participant)
        store.setActiveStudyCode(study.identity.code)

        let identity = ValidatedStudyBackendIdentity(backendInstanceID: backendID, stableStudyID: study.identity.id,
            normalizedStudyCode: study.identity.code, supportedConfigurationSchemaVersion: study.schemaVersion,
            isActive: true, validatedAt: Date())
        let descriptor = StudyBackendDescriptor(backendID: backendID, supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseAnonKey: "test-anon-key-0123456789", environment: .development, revision: 1, diagnosticName: nil)
        let services = NoopStudyServices(backendID: backendID, namespace: descriptor.authStorageNamespace)
        let backendContext = StudyBackendContext(descriptor: descriptor, identity: identity, authenticator: services,
            enrollments: services, withdrawals: services, surveyEvents: services,
            healthKitSamples: UnavailableHealthKitSampleUploadRepository(), media: mediaRepository)
        let router: (any StudyBackendRouting)? = includeRouter ? FakeStudyBackendRouting(context: backendContext) : nil

        let appState = AppState(container: AppContainer(studyConfigurationProvider: TestProvider(configuration: study),
            participantStateStore: store, healthKitService: MockHealthKitService(), notificationService: MockNotificationService(),
            systemSettingsOpener: SystemSettingsOpener(), mediaRuntime: MediaRuntime(storage: mediaStorage, thumbnailGenerator: MockMediaThumbnailGenerator(data: nil)),
            router: router))
        await appState.restoreEnrollment()
        return appState
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}
