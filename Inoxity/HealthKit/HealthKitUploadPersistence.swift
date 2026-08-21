import Foundation

struct HealthKitUploadQueueDiagnostics: Equatable, Sendable {
    let pending, acknowledged, retryNeeded, routingRequired, attentionRequired: Int
    let lastSuccessfulUpload: Date?
    static let empty = Self(pending: 0, acknowledged: 0, retryNeeded: 0, routingRequired: 0, attentionRequired: 0, lastSuccessfulUpload: nil)
}

protocol HealthKitUploadQueuePersisting: Sendable {
    func enqueue(_ samples: [HealthKitSampleUpload]) async throws
    func records(studyID: String) async -> [HealthKitSampleUpload]
    func allRecords() async -> [HealthKitSampleUpload]
    func update(_ sample: HealthKitSampleUpload) async throws
    func reset(studyID: String) async throws
    func diagnostics(studyID: String) async -> HealthKitUploadQueueDiagnostics
}

actor UserDefaultsHealthKitUploadQueue: HealthKitUploadQueuePersisting {
    static let persistenceVersion = 1
    private struct Envelope: Codable { let version: Int; var studies: [String: [HealthKitSampleUpload]] }
    private let defaults: UserDefaults; private let key: String; private var envelope: Envelope
    init(defaults: UserDefaults = .standard, key: String = "inoxity.healthkit-upload-queue.v1") {
        self.defaults = defaults; self.key = key
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Envelope.self, from: data), decoded.version == Self.persistenceVersion {
            var value = decoded
            value.studies = value.studies.mapValues { $0.map { record in
                var recovered = record; if recovered.syncStatus == .syncing { recovered.syncStatus = .pending }; return recovered
            }}
            envelope = value
        } else { envelope = .init(version: Self.persistenceVersion, studies: [:]) }
        if let data = try? JSONEncoder().encode(envelope) { defaults.set(data, forKey: key) }
    }
    func enqueue(_ samples: [HealthKitSampleUpload]) throws {
        for sample in samples {
            var values = envelope.studies[sample.stableStudyID] ?? []
            if !values.contains(where: { $0.clientSampleID == sample.clientSampleID }) { values.append(sample) }
            envelope.studies[sample.stableStudyID] = values.sorted(by: Self.order)
        }
        try save()
    }
    func records(studyID: String) -> [HealthKitSampleUpload] { envelope.studies[studyID] ?? [] }
    func allRecords() -> [HealthKitSampleUpload] { envelope.studies.values.flatMap { $0 }.sorted(by: Self.order) }
    func update(_ sample: HealthKitSampleUpload) throws {
        guard var records = envelope.studies[sample.stableStudyID], let index = records.firstIndex(where: { $0.id == sample.id }) else { return }
        records[index] = sample; envelope.studies[sample.stableStudyID] = records.sorted(by: Self.order); try save()
    }
    func reset(studyID: String) throws { envelope.studies.removeValue(forKey: studyID); try save() }
    func diagnostics(studyID: String) -> HealthKitUploadQueueDiagnostics {
        let values = envelope.studies[studyID] ?? []
        return .init(pending: values.filter { $0.syncStatus == .pending || $0.syncStatus == .syncing }.count,
            acknowledged: values.filter { $0.syncStatus == .acknowledged }.count,
            retryNeeded: values.filter { $0.syncStatus == .retryableFailure }.count,
            routingRequired: values.filter { $0.syncStatus == .routingRequired }.count,
            attentionRequired: values.filter { $0.syncStatus == .attentionRequired }.count,
            lastSuccessfulUpload: values.compactMap(\.acknowledgedAt).max())
    }
    private static func order(_ lhs: HealthKitSampleUpload, _ rhs: HealthKitSampleUpload) -> Bool {
        if lhs.sampleStart != rhs.sampleStart { return lhs.sampleStart < rhs.sampleStart }
        if lhs.healthKitIdentifier != rhs.healthKitIdentifier { return lhs.healthKitIdentifier < rhs.healthKitIdentifier }
        return lhs.clientSampleID < rhs.clientSampleID
    }
    private func save() throws { defaults.set(try JSONEncoder().encode(envelope), forKey: key) }
}

enum HealthKitCursorStatus: String, Codable, Equatable, Sendable { case ready, awaitingAcknowledgments, attentionRequired }
struct HealthKitSyncCursorKey: Codable, Hashable, Sendable {
    let stableStudyID: String; let remoteEnrollmentID: UUID; let studyBackendID: UUID
    let descriptorCacheKey: String; let healthKitIdentifier: String; let configurationRevision: Int
    var storageKey: String { [stableStudyID, remoteEnrollmentID.uuidString, studyBackendID.uuidString, descriptorCacheKey, healthKitIdentifier, String(configurationRevision)].joined(separator: "|") }
}
struct HealthKitSyncCursor: Codable, Equatable, Sendable {
    let key: HealthKitSyncCursorKey
    var committedAnchor: Data?
    var candidateAnchor: Data?
    var candidateRequiredSampleIDs: [String]
    var lastQueryAttempt: Date?
    var lastSuccessfulPromotion: Date?
    var status: HealthKitCursorStatus
}
protocol HealthKitSyncCursorPersisting: Sendable {
    func cursor(for key: HealthKitSyncCursorKey) async -> HealthKitSyncCursor?
    func save(_ cursor: HealthKitSyncCursor) async throws
    func cursors(studyID: String) async -> [HealthKitSyncCursor]
    func reset(studyID: String) async throws
}
actor UserDefaultsHealthKitSyncCursorStore: HealthKitSyncCursorPersisting {
    static let persistenceVersion = 1
    private struct Envelope: Codable { let version: Int; var cursors: [String: HealthKitSyncCursor] }
    private let defaults: UserDefaults; private let key: String; private var envelope: Envelope
    init(defaults: UserDefaults = .standard, key: String = "inoxity.healthkit-cursors.v1") {
        self.defaults = defaults; self.key = key
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Envelope.self, from: data), decoded.version == Self.persistenceVersion { envelope = decoded }
        else { envelope = .init(version: Self.persistenceVersion, cursors: [:]) }
        if let data = try? JSONEncoder().encode(envelope) { defaults.set(data, forKey: key) }
    }
    func cursor(for key: HealthKitSyncCursorKey) -> HealthKitSyncCursor? { envelope.cursors[key.storageKey] }
    func save(_ cursor: HealthKitSyncCursor) throws { envelope.cursors[cursor.key.storageKey] = cursor; try saveEnvelope() }
    func cursors(studyID: String) -> [HealthKitSyncCursor] { envelope.cursors.values.filter { $0.key.stableStudyID == studyID } }
    func reset(studyID: String) throws { envelope.cursors = envelope.cursors.filter { $0.value.key.stableStudyID != studyID }; try saveEnvelope() }
    private func saveEnvelope() throws { defaults.set(try JSONEncoder().encode(envelope), forKey: key) }
}
