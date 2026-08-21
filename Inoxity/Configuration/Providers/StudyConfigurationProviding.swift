import Foundation

protocol StudyConfigurationProviding: Sendable {
    func configuration(for studyCode: String) async throws -> StudyConfiguration
}

struct BundledStudyConfigurationProvider: StudyConfigurationProviding {
    private let bundle: Bundle
    private let validator: StudyConfigurationValidator
    private let resources: [String: String]

    init(bundle: Bundle = .main, validator: StudyConfigurationValidator = .init(),
         resources: [String: String] = ["SLEEP01": "SleepStudy", "ACTIVITY02": "ActivityStudy"]) {
        self.bundle = bundle; self.validator = validator; self.resources = resources
    }

    func configuration(for studyCode: String) async throws -> StudyConfiguration {
        let code = StudyCodeNormalizer.normalize(studyCode)
        guard let name = resources[code] else { throw StudyConfigurationError.unknownCode }
        guard let url = bundle.url(forResource: name, withExtension: "json") else { throw StudyConfigurationError.missingResource }
        let data = try Data(contentsOf: url)
        let configuration: StudyConfiguration
        do { configuration = try JSONDecoder().decode(StudyConfiguration.self, from: data) }
        catch { throw StudyConfigurationError.malformedConfiguration }
        try validator.validate(configuration, expectedCode: code)
        return configuration
    }
}
