import Foundation

/// Which part of enrollment was running when something failed.
enum EnrollmentStage: String, Sendable {
    case inoxitySignIn = "Signing in to Inoxity"
    case studyLookup = "Looking up the study code"
    case studyDatabaseSignIn = "Signing in to the study database"
    case studyDatabaseCheck = "Checking the study database"
    case registration = "Registering the enrollment"
}

/// A raw failure noted where a server error is converted into the app's own error types (which
/// otherwise discard it), so an enrollment error can say what actually went wrong.
struct EnrollmentFailureNote: Equatable, Sendable {
    let stage: EnrollmentStage
    let detail: String
    let urlErrorCode: Int?
}

final class EnrollmentDiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EnrollmentFailureNote] = []
    var notes: [EnrollmentFailureNote] { lock.withLock { storage } }
    func add(_ note: EnrollmentFailureNote) { lock.withLock { storage.append(note) } }
}

/// Collects raw failures for one enrollment attempt. The recorder is task-local, so only work
/// started inside `AppState`'s enrollment calls records anything; a background sync running at
/// the same time can't mix its failures into an enrollment report.
enum EnrollmentDiagnostics {
    @TaskLocal static var recorder: EnrollmentDiagnosticsRecorder?

    static func record(_ error: Error, stage: EnrollmentStage) {
        recorder?.add(.init(stage: stage, detail: String(describing: error), urlErrorCode: (error as? URLError)?.code.rawValue))
    }
    static func record(detail: String, stage: EnrollmentStage) {
        recorder?.add(.init(stage: stage, detail: detail, urlErrorCode: nil))
    }
}

/// What a participant sees when enrollment fails: a plain-language message plus a short code the
/// research team can look up in the docs' troubleshooting page ("Enrollment error codes"), and
/// the details behind "Copy error details".
struct EnrollmentErrorReport: Equatable, Sendable {
    let code: String
    let message: String
    let stage: EnrollmentStage?
    let detail: String?
    let occurredAt: Date

    /// Text for "Copy error details": everything needed to find the cause, and nothing personal.
    func copyText(studyCode: String?, appVersion: String, environment: String?) -> String {
        var lines = ["Inoxity error \(code)", message]
        if let stage { lines.append("Step: \(stage.rawValue)") }
        lines.append("Time: \(occurredAt.formatted(date: .abbreviated, time: .standard)) (\(TimeZone.current.identifier))")
        lines.append("App: \(appVersion)\(environment.map { ", \($0)" } ?? "")")
        if let studyCode, !studyCode.isEmpty { lines.append("Study code: \(studyCode)") }
        if let detail { lines.append("Details: \(detail)") }
        return lines.joined(separator: "\n")
    }

    static func make(from error: Error, notes: [EnrollmentFailureNote], at date: Date) -> EnrollmentErrorReport {
        let lastNote = notes.last
        let raw = notes.map(\.detail).joined(separator: " | ").lowercased()
        let code = classify(error, notes: notes, raw: raw)
        let detail = notes.isEmpty ? sanitize(String(describing: error)) : sanitize(notes.map { "\($0.stage.rawValue): \($0.detail)" }.joined(separator: " | "))
        // A study's own status (paused, closed, not started) carries the researcher's message.
        let message: String
        switch error {
        case StudyConfigurationError.unavailable, StudyConfigurationError.notStarted, StudyConfigurationError.ended:
            message = (error as? LocalizedError)?.errorDescription ?? code.message
        default: message = code.message
        }
        return .init(code: code.rawValue, message: message, stage: lastNote?.stage, detail: detail, occurredAt: date)
    }

    private static func classify(_ error: Error, notes: [EnrollmentFailureNote], raw: String) -> EnrollmentErrorCode {
        let offlineCodes: Set<Int> = [URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue,
                                      URLError.dataNotAllowed.rawValue, URLError.internationalRoamingOff.rawValue]
        if notes.contains(where: { $0.urlErrorCode.map(offlineCodes.contains) == true })
            || (error as? URLError).map({ offlineCodes.contains($0.code.rawValue) }) == true { return .offline }
        switch error {
        case RemoteStudyError.notFound, StudyConfigurationError.unknownCode: return .studyNotFound
        case StudyConfigurationError.unavailable, StudyConfigurationError.ended: return .studyNotAccepting
        case StudyConfigurationError.notStarted: return .enrollmentNotOpen
        case StudyConfigurationError.unsupportedSchema: return .appTooOld
        case RemoteStudyError.inactive: return .studyNotAccepting
        case RemoteStudyError.enrollmentNotOpen: return .enrollmentNotOpen
        case RemoteStudyError.enrollmentClosed: return .enrollmentClosed
        case RemoteStudyError.unsupportedConfiguration: return .appTooOld
        case RemoteStudyError.invalidConfiguration:
            return raw.contains("study_backend_unavailable") ? .dataBackendNotSet : .studySettingsInvalid
        case RemoteStudyError.unauthorized: return .inoxityPermissions
        case BackendError.crossEnvironmentDescriptor: return .environmentMismatch
        case BackendError.malformedURL, BackendError.invalidDescriptor: return .dataBackendSettingsInvalid
        case BackendError.missingConfiguration: return .appBuildMisconfigured
        case BackendError.inactiveBackend: return .studyDatabaseInactive
        case BackendError.backendIdentityMismatch, BackendError.routingRequired, BackendError.ownershipDenied: return .studyDatabaseMismatch
        case BackendError.withdrawnEnrollment: return .reenrollmentBlocked
        default: break
        }
        // What's left is a generic "unavailable"-style failure: use the raw detail and where it
        // happened to tell a setup problem from an unreachable server.
        if let anonymousOff = notes.last(where: { note in
            let text = note.detail.lowercased()
            return text.contains("anonymous") && (text.contains("disabled") || text.contains("not enabled"))
        }) {
            // Either Supabase project can have anonymous sign-ins off; which one decides the fix.
            return anonymousOff.stage == .inoxitySignIn ? .inoxityPermissions : .anonymousSignInOff
        }
        if raw.contains("could not find the function") || raw.contains("pgrst202") || raw.contains("does not exist")
            || raw.contains("schema cache") || raw.contains(Self.identityRowMissing.lowercased()) { return .studyDatabaseSetupIncomplete }
        guard let stage = notes.last?.stage else {
            return error is RemoteStudyError ? .inoxityUnreachable : .unknown
        }
        switch stage {
        case .inoxitySignIn, .studyLookup: return .inoxityUnreachable
        case .studyDatabaseSignIn, .studyDatabaseCheck, .registration: return .studyDatabaseUnreachable
        }
    }

    /// Recorded when the study database answers but has no identity row, i.e. its setup SQL ran
    /// without the README's identity insert.
    static let identityRowMissing = "get_study_backend_identity returned no rows (identity row missing)"

    /// Strips anything credential-like before details are shown or copied.
    static func sanitize(_ text: String) -> String {
        var value = text
        for pattern in [#"apikey=[^&\s"]+"#, #"(?i)bearer\s+[A-Za-z0-9._-]+"#, #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return value.count > 600 ? String(value.prefix(600)) + "…" : value
    }
}

/// Short codes a participant can read out to the research team. The docs' "Enrollment error
/// codes" table (inoxity-dashboard docs/troubleshooting.md) explains each one and where to look;
/// keep the two in sync.
enum EnrollmentErrorCode: String, Sendable {
    case offline = "E01", inoxityUnreachable = "E02", studyNotFound = "E03", studyNotAccepting = "E04"
    case enrollmentNotOpen = "E05", enrollmentClosed = "E06", inoxityPermissions = "E07"
    case studyDatabaseUnreachable = "E10", anonymousSignInOff = "E11", studyDatabaseSetupIncomplete = "E12"
    case studyDatabaseMismatch = "E13", environmentMismatch = "E14", studyDatabaseInactive = "E15"
    case reenrollmentBlocked = "E16"
    case appTooOld = "E20", studySettingsInvalid = "E21", dataBackendNotSet = "E22", dataBackendSettingsInvalid = "E23"
    case appBuildMisconfigured = "E24", unknown = "E99"

    var message: String {
        let contact = "Please contact the research team and mention code \(rawValue)."
        switch self {
        case .offline: return "You appear to be offline. Check your internet connection and try again."
        case .inoxityUnreachable: return "Inoxity’s server couldn’t be reached. Please try again in a few minutes. If it keeps happening, contact the research team and mention code \(rawValue)."
        case .studyNotFound: return "That study code wasn’t found. Check the code and try again."
        case .studyNotAccepting: return "This study isn’t accepting participants right now."
        case .enrollmentNotOpen: return "Enrollment for this study hasn’t opened yet."
        case .enrollmentClosed: return "Enrollment for this study has closed."
        case .studyDatabaseUnreachable: return "This study’s data service isn’t responding. Please try again later. If it keeps happening, contact the research team and mention code \(rawValue)."
        case .appTooOld: return "This study needs a newer version of Inoxity. Please update the app and try again."
        case .reenrollmentBlocked: return "This study was previously withdrawn on this device and can’t be rejoined automatically. \(contact)"
        case .inoxityPermissions, .anonymousSignInOff, .studyDatabaseSetupIncomplete, .studyDatabaseMismatch,
             .environmentMismatch, .studyDatabaseInactive, .studySettingsInvalid, .dataBackendNotSet,
             .dataBackendSettingsInvalid, .appBuildMisconfigured:
            return "This study isn’t set up correctly, so you can’t join it yet. \(contact)"
        case .unknown: return "Something went wrong while joining this study. \(contact)"
        }
    }
}
