import Foundation

enum HealthKitSampleKind: String, Codable, Equatable, Sendable { case quantity, category, workout, correlation }
enum HealthKitUploadSyncStatus: String, Codable, Equatable, Sendable {
    case pending, syncing, acknowledged, retryableFailure, routingRequired, attentionRequired
}

struct HealthKitSampleUpload: Codable, Equatable, Identifiable, Sendable {
    var id: String { clientSampleID }
    let clientSampleID: String
    let sampleUUID: UUID
    let stableStudyID: String
    let remoteEnrollmentID: UUID
    let studyBackendID: UUID
    let descriptorCacheKey: String
    let healthKitIdentifier: String
    let sampleKind: HealthKitSampleKind
    let sampleStart: Date
    let sampleEnd: Date
    /// IANA identifier (e.g. "America/Los_Angeles") for the zone the sample actually occurred in —
    /// read off the sample's own `HKMetadataKeyTimeZone` metadata when present (correct even for
    /// backfilled historical data from a device that has since traveled), falling back to the
    /// current device zone when a source didn't populate it. `sample_start`/`sample_end` stay
    /// UTC-only `timestamptz`; this is what lets local wall-clock time be reconstructed later via
    /// `timestamptz AT TIME ZONE sample_time_zone` instead of guessing at analysis time.
    let sampleTimeZoneIdentifier: String
    let quantityValue: Double?
    let quantityUnit: String?
    let categoryValue: Int?
    let workoutActivityType: UInt?
    let workoutDurationSeconds: Double?
    /// Second value for a correlation sample (e.g. blood pressure's diastolic reading, with
    /// `quantityValue` holding systolic) — nil for every other sample kind.
    let secondaryQuantityValue: Double?
    let configurationSchemaVersion: Int
    let configurationRevision: Int
    let createdAt: Date
    var syncStatus: HealthKitUploadSyncStatus
    var retryCount: Int
    var lastAttemptAt: Date?
    var failureCategory: BackendFailureCategory?
    var acknowledgedAt: Date?
    var remoteAcknowledgmentID: UUID?
}

struct HealthKitRawSample: Equatable, Sendable {
    let uuid: UUID
    let identifier: String
    let kind: HealthKitSampleKind
    let start: Date
    let end: Date
    /// See `HealthKitSampleUpload.sampleTimeZoneIdentifier`.
    let timeZoneIdentifier: String
    let quantityValue: Double?
    let canonicalUnit: String?
    let categoryValue: Int?
    let workoutActivityType: UInt?
    let workoutDurationSeconds: Double?
    /// See `HealthKitSampleUpload.secondaryQuantityValue` — populated only for `.correlation` kind.
    let secondaryQuantityValue: Double?

    // An inline default (`= nil`) on a `let` property is silently excluded from being
    // explicitly settable in the synthesized memberwise initializer (the parameter exists but
    // always resolves to the literal default) — the same class of bug already hit once in this
    // codebase for `ReminderScheduleConfiguration.anchor`/`offsetMinutes` (see
    // StudyConfiguration.swift), just biting the memberwise init here instead of Codable
    // decoding. This explicit init keeps every other call site's omission working while letting
    // the `.correlation` branch below pass `secondaryQuantityValue` explicitly.
    init(uuid: UUID, identifier: String, kind: HealthKitSampleKind, start: Date, end: Date,
         timeZoneIdentifier: String, quantityValue: Double?, canonicalUnit: String?, categoryValue: Int?,
         workoutActivityType: UInt?, workoutDurationSeconds: Double?,
         secondaryQuantityValue: Double? = nil) {
        self.uuid = uuid; self.identifier = identifier; self.kind = kind
        self.start = start; self.end = end; self.timeZoneIdentifier = timeZoneIdentifier
        self.quantityValue = quantityValue
        self.canonicalUnit = canonicalUnit; self.categoryValue = categoryValue
        self.workoutActivityType = workoutActivityType; self.workoutDurationSeconds = workoutDurationSeconds
        self.secondaryQuantityValue = secondaryQuantityValue
    }
}

struct HealthKitSampleQueryPage: Equatable, Sendable {
    let samples: [HealthKitRawSample]
    let nextAnchor: Data
    let hasMore: Bool
    let ignoredDeletionCount: Int
}

enum HealthKitUploadError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedIdentifier(String), invalidSample, invalidUnit, invalidBatchSize
    case routingRequired, configurationMismatch, malformedCursor, unavailable, conflictingDuplicate
    var errorDescription: String? {
        switch self {
        case .unsupportedIdentifier: "This study requested an unsupported Apple Health data type."
        case .invalidSample, .invalidUnit: "An Apple Health sample could not be prepared safely."
        case .invalidBatchSize: "The Apple Health upload batch was too large."
        case .routingRequired: "The study connection must be restored before Apple Health data can sync."
        case .configurationMismatch: "The saved Apple Health sync state belongs to a different study configuration."
        case .malformedCursor: "Saved Apple Health sync progress could not be restored safely."
        case .unavailable: "Apple Health upload is temporarily unavailable."
        case .conflictingDuplicate: "The Study Backend reported conflicting Apple Health data."
        }
    }
}

enum HealthKitSampleIdentityFactory {
    static func id(studyID: String, identifier: String, sampleUUID: UUID) -> String {
        "healthkit.\(studyID).\(identifier).\(sampleUUID.uuidString.lowercased())"
    }
}

struct HealthKitUploadPolicy: Equatable, Sendable {
    let initialHistoryDays: Int
    let maximumQueryPageSize: Int
    let maximumUploadBatchSize: Int
    let overlapMinutes: Int
    static let phase3D = Self(initialHistoryDays: 30, maximumQueryPageSize: 250,
                             maximumUploadBatchSize: 250, overlapMinutes: 5)
}

struct HealthKitSampleAcknowledgment: Codable, Equatable, Sendable {
    let clientSampleID: String
    let acknowledgmentID: UUID
    let receivedAt: Date
    let idempotentExisting: Bool
}
struct HealthKitBatchAcknowledgment: Equatable, Sendable { let acknowledgments: [HealthKitSampleAcknowledgment] }

enum HealthKitCanonicalUnit {
    /// Reads straight off `HealthKitTypeRegistry` instead of maintaining a second, separately-kept
    /// identifier→unit switch — the registry's `canonicalUploadUnit` already carries exactly this.
    static func forIdentifier(_ identifier: String) -> String? {
        try? HealthKitTypeRegistry.type(for: identifier).canonicalUploadUnit
    }
}

enum HealthKitSampleNormalizer {
    static func normalize(_ raw: HealthKitRawSample, participant: ParticipantState, now: Date) throws -> HealthKitSampleUpload {
        guard raw.end >= raw.start, let metadata = try? HealthKitTypeRegistry.type(for: raw.identifier),
              // Cross-check against the registry's own sampleKind, not just "identifier is
              // supported at all" — catches a raw sample built with the wrong kind for its
              // identifier (e.g. a would-be quantity sample tagged .category), the same class of
              // bug the old `raw.identifier == "sleepAnalysis"`/`"workout"` literal checks caught
              // for the two kinds that used to exist, now generalized to every kind/identifier.
              metadata.sampleKind == raw.kind,
              let enrollment = participant.remoteEnrollmentID, let backend = participant.studyBackendID,
              let cacheKey = participant.studyBackendDescriptorCacheKey,
              let schema = participant.enrolledConfigurationSchemaVersion, schema > 0,
              let revision = participant.enrolledConfigurationRevision, revision > 0 else { throw HealthKitUploadError.invalidSample }
        switch raw.kind {
        case .quantity:
            guard let value = raw.quantityValue, value.isFinite, value >= 0,
                  raw.canonicalUnit == HealthKitCanonicalUnit.forIdentifier(raw.identifier) else { throw HealthKitUploadError.invalidUnit }
        case .category:
            guard raw.categoryValue != nil else { throw HealthKitUploadError.invalidSample }
        case .workout:
            guard let duration = raw.workoutDurationSeconds,
                  duration.isFinite, duration >= 0, raw.workoutActivityType != nil else { throw HealthKitUploadError.invalidSample }
        case .correlation:
            guard let systolic = raw.quantityValue, systolic.isFinite, systolic >= 0,
                  let diastolic = raw.secondaryQuantityValue, diastolic.isFinite, diastolic >= 0
            else { throw HealthKitUploadError.invalidSample }
        }
        return .init(clientSampleID: HealthKitSampleIdentityFactory.id(studyID: participant.studyID, identifier: raw.identifier, sampleUUID: raw.uuid),
            sampleUUID: raw.uuid, stableStudyID: participant.studyID, remoteEnrollmentID: enrollment,
            studyBackendID: backend, descriptorCacheKey: cacheKey, healthKitIdentifier: raw.identifier,
            sampleKind: raw.kind, sampleStart: raw.start, sampleEnd: raw.end,
            sampleTimeZoneIdentifier: raw.timeZoneIdentifier,
            quantityValue: raw.quantityValue, quantityUnit: raw.canonicalUnit, categoryValue: raw.categoryValue,
            workoutActivityType: raw.workoutActivityType, workoutDurationSeconds: raw.workoutDurationSeconds,
            secondaryQuantityValue: raw.secondaryQuantityValue,
            configurationSchemaVersion: schema, configurationRevision: revision, createdAt: now,
            syncStatus: .pending, retryCount: 0, lastAttemptAt: nil, failureCategory: nil,
            acknowledgedAt: nil, remoteAcknowledgmentID: nil)
    }
}
