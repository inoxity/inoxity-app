import Foundation

enum HealthKitRequestState: String, Codable, Equatable, Sendable {
    case notRequested
    case requestCompleted
    case attentionNeeded
}

enum HealthKitRuntimeStatus: Equatable, Sendable {
    case notRequested
    case requestCompleted
    /// The authorization request completed, but a pre-check showed every requested data type already
    /// had an OS-level decision from a previous study/install — so no new permission sheet appeared.
    /// This is the "some types were already granted/denied elsewhere" case the UI should surface.
    case completedWithoutPrompt
    case unavailable
    case attentionNeeded(String)
    case syncing
    case syncSucceeded(HealthKitLocalSyncSummary)
    case syncFailed(String)
}

/// Mirrors `HKAuthorizationRequestStatus`, reported for the *whole* requested set — Apple does not
/// expose a per-type breakdown for read-only data, and does not reveal grant vs. deny either way.
enum HealthKitAuthorizationPreCheck: Equatable, Sendable {
    case shouldRequest
    case unnecessary
    case unknown
}

enum HealthKitAuthorizationRequestResult: Equatable, Sendable {
    case completed
    case attentionNeeded(String)
}

struct HealthKitLocalSyncSummary: Equatable, Sendable {
    let completedAt: Date
    let metrics: [HealthKitLocalMetric]
}

struct HealthKitLocalMetric: Equatable, Identifiable, Sendable {
    let identifier: String
    let label: String
    let value: String

    var id: String { identifier }
}

enum HealthKitServiceError: Error, Equatable, LocalizedError {
    case unavailable
    case disabled
    case emptyReadSet
    case unsupportedIdentifier(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Health is unavailable on this device."
        case .disabled: "Apple Health is not enabled for this study."
        case .emptyReadSet: "This study has no Apple Health data types configured."
        case .unsupportedIdentifier(let identifier): "The Apple Health data type ‘\(identifier)’ is not supported."
        case .queryFailed(let message): "Local Apple Health sync failed: \(message)"
        }
    }
}
