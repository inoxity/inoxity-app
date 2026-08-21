import Foundation

enum StudyConfigurationSource: String, Codable, Equatable, Sendable { case remote, cache, bundled }
enum EnrollmentSyncStatus: String, Codable, Equatable, Sendable { case provisional, registered, failedRetryable }
enum BackendRoutingStatus: String, Codable, Equatable, Sendable {
    case legacyUnrouted, descriptorCached, identityVerified, registered, routingRequired
}
enum BackendFailureCategory: String, Codable, Equatable, Sendable { case unavailable, timeout, rateLimited, server, authentication, authorization, validation, unknown }

struct BackendSyncSummary: Codable, Equatable, Sendable {
    let completedAt: Date
    let succeeded: Int
    let retryableFailures: Int
    let nonRetryableFailures: Int
}

struct AuthenticatedParticipant: Equatable, Sendable {
    let authUserID: UUID
    let isAnonymous: Bool
    let createdAt: Date?
}

struct StudyBackendDescriptor: Codable, Equatable, Sendable {
    let backendID: UUID
    let supabaseURL: URL
    let supabaseAnonKey: String
    let environment: BackendEnvironmentName
    let revision: Int
    let diagnosticName: String?

    func validated(for expectedEnvironment: BackendEnvironmentName) throws -> Self {
        guard environment == expectedEnvironment else { throw BackendError.crossEnvironmentDescriptor }
        guard supabaseURL.scheme == "https", supabaseURL.host != nil, supabaseURL.user == nil,
              supabaseURL.password == nil else { throw BackendError.malformedURL }
        let key = supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision > 0, key.count >= 20, !key.contains(where: \.isWhitespace),
              !key.localizedCaseInsensitiveContains("replace_me") else {
            throw BackendError.invalidDescriptor
        }
        return self
    }

    var authStorageNamespace: String {
        "inoxity.study.\(backendID.uuidString.lowercased()).\(environment.rawValue.lowercased())"
    }
}

struct ValidatedStudyBackendIdentity: Codable, Equatable, Sendable {
    let backendInstanceID: UUID
    let stableStudyID: String
    let normalizedStudyCode: String
    let supportedConfigurationSchemaVersion: Int
    let isActive: Bool
    let validatedAt: Date

    // validatedAt records when this snapshot was fetched, not what was verified — two independent
    // RPC calls (e.g. at study-code resolution vs. at enrollment) always produce different
    // timestamps, so including it here would make this identity check fail unconditionally.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backendInstanceID == rhs.backendInstanceID && lhs.stableStudyID == rhs.stableStudyID
            && lhs.normalizedStudyCode == rhs.normalizedStudyCode
            && lhs.supportedConfigurationSchemaVersion == rhs.supportedConfigurationSchemaVersion
            && lhs.isActive == rhs.isActive
    }
}

struct ResolvedStudy: Equatable, Sendable {
    let configuration: StudyConfiguration
    let stableStudyID: String
    let normalizedStudyCode: String
    let configurationSchemaVersion: Int
    let configurationRevision: Int
    let source: StudyConfigurationSource
    let descriptor: StudyBackendDescriptor
    let validatedIdentity: ValidatedStudyBackendIdentity
    let controlEnvironment: BackendEnvironmentName
    let fetchedAt: Date
    let bootstrapCacheKey: String
}

struct ControlStudyBootstrap: Equatable, Sendable {
    let controlStudyID: UUID
    let configuration: StudyConfiguration
    let stableStudyID: String
    let normalizedStudyCode: String
    let configurationSchemaVersion: Int
    let configurationRevision: Int
    let descriptor: StudyBackendDescriptor
    let fetchedAt: Date
}

struct StudyBackendContext: Sendable {
    let descriptor: StudyBackendDescriptor
    let identity: ValidatedStudyBackendIdentity
    let authenticator: any StudyBackendAuthenticating
    let enrollments: any RemoteEnrollmentRepository
    let withdrawals: any RemoteWithdrawalRepository
    let surveyEvents: any SurveyEventUploadRepository
    let healthKitSamples: any HealthKitSampleUploadRepository
    let media: any MediaUploadRepository
}

struct RemoteParticipant: Equatable, Sendable { let id: UUID; let createdAt: Date }

struct RemoteStudyConfiguration: Equatable, Sendable {
    let remoteStudyID: UUID?
    let configuration: StudyConfiguration
    let configurationSchemaVersion: Int
    let configurationRevision: Int
    let fetchedAt: Date
    let source: StudyConfigurationSource
    var cacheKey: String { "\(configuration.identity.id)/\(configurationRevision)" }
}

struct RemoteEnrollment: Equatable, Sendable {
    let enrollmentID: UUID
    let participantID: UUID
    let remoteStudyID: UUID
    let status: String
    let enrolledAt: Date
    let configurationSchemaVersion: Int
    let configurationRevision: Int
}

struct EnrollmentRegistration: Equatable, Sendable {
    let stableStudyID: String
    let participantIdentifier: String
    let enrollmentAttemptID: UUID
    let installationID: UUID
    let configurationSchemaVersion: Int
    let configurationRevision: Int
}

enum RemoteStudyError: Error, Equatable, LocalizedError, Sendable {
    case notFound, inactive, enrollmentNotOpen, enrollmentClosed, unsupportedConfiguration
    case invalidConfiguration, unavailable, unauthorized, unknown
    var errorDescription: String? {
        switch self {
        case .notFound: "That study code was not found."
        case .inactive: "This study is not currently accepting participants."
        case .enrollmentNotOpen: "Enrollment for this study has not opened yet."
        case .enrollmentClosed: "Enrollment for this study has closed."
        case .unsupportedConfiguration, .invalidConfiguration: "This study configuration cannot be used by this version of Inoxity."
        case .unavailable: "Inoxity could not connect to the study service. Please try again."
        case .unauthorized: "A secure connection could not be established. Please try again."
        case .unknown: "The study service could not complete the request."
        }
    }
}

enum BackendError: Error, Equatable, LocalizedError, Sendable {
    case missingConfiguration, malformedURL, invalidDescriptor, crossEnvironmentDescriptor
    case unavailable, unauthorized, ownershipDenied, invalidResponse, withdrawnEnrollment, backendIdentityMismatch, inactiveBackend, routingRequired
    var errorDescription: String? {
        switch self {
        case .missingConfiguration, .malformedURL, .invalidDescriptor, .crossEnvironmentDescriptor:
            "The study service is not configured correctly for this study."
        case .unavailable: "The study service is temporarily unavailable."
        case .unauthorized: "A secure session could not be established."
        case .ownershipDenied: "The study service could not verify this enrollment."
        case .invalidResponse: "The study service returned an invalid response."
        case .withdrawnEnrollment: "This study was previously withdrawn and cannot be reactivated automatically."
        case .backendIdentityMismatch: "This study’s secure connection could not be verified. No participant data was sent."
        case .inactiveBackend: "This study is not currently accepting new data. No participant data was sent."
        case .routingRequired: "This pending operation needs its original study connection before it can be synchronized."
        }
    }
}
