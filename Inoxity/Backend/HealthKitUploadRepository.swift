import Foundation

protocol HealthKitSampleUploadRepository: Sendable {
    func submitHealthKitSamples(_ samples: [HealthKitSampleUpload]) async throws -> HealthKitBatchAcknowledgment
}

struct UnavailableHealthKitSampleUploadRepository: HealthKitSampleUploadRepository {
    func submitHealthKitSamples(_ samples: [HealthKitSampleUpload]) async throws -> HealthKitBatchAcknowledgment {
        throw HealthKitUploadError.unavailable
    }
}
