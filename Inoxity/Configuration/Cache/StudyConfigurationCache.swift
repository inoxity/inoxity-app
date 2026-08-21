import Foundation

protocol StudyBootstrapCaching: Sendable {
    func save(_ value: ResolvedStudy) async throws
    func bootstrap(cacheKey: String, environment: BackendEnvironmentName,
                   studyID: String, backendID: UUID) async throws -> ResolvedStudy?
    func latest(code: String, environment: BackendEnvironmentName) async throws -> ResolvedStudy?
}

actor FileStudyBootstrapCache: StudyBootstrapCaching {
    struct Entry: Codable, Equatable, Sendable {
        static let currentVersion = 2
        let persistenceVersion: Int
        let configuration: StudyConfiguration
        let stableStudyID: String
        let normalizedStudyCode: String
        let configurationSchemaVersion: Int
        let configurationRevision: Int
        let controlEnvironment: BackendEnvironmentName
        let descriptor: StudyBackendDescriptor
        let validatedIdentity: ValidatedStudyBackendIdentity
        let fetchedAt: Date
    }
    private let root: URL
    private let encoder = JSONEncoder(), decoder = JSONDecoder()
    private let validator = StudyConfigurationValidator()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBootstraps", isDirectory: true)
        encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
    }

    func save(_ value: ResolvedStudy) throws {
        try validate(value)
        let folder = try directory(environment: value.controlEnvironment, studyID: value.stableStudyID,
                                   configRevision: value.configurationRevision,
                                   descriptorRevision: value.descriptor.revision)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let entry = Entry(persistenceVersion: Entry.currentVersion, configuration: value.configuration,
                          stableStudyID: value.stableStudyID, normalizedStudyCode: value.normalizedStudyCode,
                          configurationSchemaVersion: value.configurationSchemaVersion,
                          configurationRevision: value.configurationRevision, controlEnvironment: value.controlEnvironment,
                          descriptor: value.descriptor, validatedIdentity: value.validatedIdentity, fetchedAt: value.fetchedAt)
        let temporary = folder.appendingPathExtension("tmp-\(UUID().uuidString)")
        try encoder.encode(entry).write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        var temp = temporary; try? temp.setResourceValues(resources)
        if FileManager.default.fileExists(atPath: folder.path) { _ = try FileManager.default.replaceItemAt(folder, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: folder) }
    }

    func bootstrap(cacheKey: String, environment: BackendEnvironmentName,
                   studyID: String, backendID: UUID) throws -> ResolvedStudy? {
        guard safeKey(cacheKey), safe(studyID) else { throw RemoteStudyError.invalidConfiguration }
        let url = root.appendingPathComponent(environment.rawValue).appendingPathComponent(studyID).appendingPathComponent(cacheKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try load(url)
        guard value.stableStudyID == studyID, value.descriptor.backendID == backendID else { throw RemoteStudyError.invalidConfiguration }
        return value
    }

    func latest(code: String, environment: BackendEnvironmentName) throws -> ResolvedStudy? {
        let normalized = StudyCodeNormalizer.normalize(code)
        let env = root.appendingPathComponent(environment.rawValue)
        guard FileManager.default.fileExists(atPath: env.path) else { return nil }
        let files = try FileManager.default.subpathsOfDirectory(atPath: env.path)
            .filter { $0.hasSuffix(".bootstrap") }.sorted().reversed()
        for path in files {
            if let value = try? load(env.appendingPathComponent(path)), value.normalizedStudyCode == normalized { return value }
        }
        return nil
    }

    private func load(_ url: URL) throws -> ResolvedStudy {
        let entry: Entry
        do { entry = try decoder.decode(Entry.self, from: Data(contentsOf: url)) }
        catch { throw RemoteStudyError.invalidConfiguration }
        guard entry.persistenceVersion == Entry.currentVersion else { throw RemoteStudyError.invalidConfiguration }
        let key = Self.cacheKey(configurationRevision: entry.configurationRevision,
                                descriptorRevision: entry.descriptor.revision)
        let value = ResolvedStudy(configuration: entry.configuration, stableStudyID: entry.stableStudyID,
            normalizedStudyCode: entry.normalizedStudyCode,
            configurationSchemaVersion: entry.configurationSchemaVersion,
            configurationRevision: entry.configurationRevision, source: .cache, descriptor: entry.descriptor,
            validatedIdentity: entry.validatedIdentity, controlEnvironment: entry.controlEnvironment,
            fetchedAt: entry.fetchedAt, bootstrapCacheKey: key)
        try validate(value); return value
    }

    private func validate(_ value: ResolvedStudy) throws {
        try validator.validate(value.configuration, expectedCode: value.normalizedStudyCode)
        _ = try value.descriptor.validated(for: value.controlEnvironment)
        guard value.stableStudyID == value.configuration.identity.id,
              value.configurationSchemaVersion == value.configuration.schemaVersion,
              value.configurationRevision > 0,
              value.validatedIdentity.backendInstanceID == value.descriptor.backendID,
              value.validatedIdentity.stableStudyID == value.stableStudyID,
              value.validatedIdentity.normalizedStudyCode == value.normalizedStudyCode,
              value.validatedIdentity.supportedConfigurationSchemaVersion == value.configurationSchemaVersion,
              value.validatedIdentity.isActive else { throw RemoteStudyError.invalidConfiguration }
    }
    private func directory(environment: BackendEnvironmentName, studyID: String,
                           configRevision: Int, descriptorRevision: Int) throws -> URL {
        guard safe(studyID), configRevision > 0, descriptorRevision > 0 else { throw RemoteStudyError.invalidConfiguration }
        return root.appendingPathComponent(environment.rawValue).appendingPathComponent(studyID)
            .appendingPathComponent(Self.cacheKey(configurationRevision: configRevision, descriptorRevision: descriptorRevision))
    }
    static func cacheKey(configurationRevision: Int, descriptorRevision: Int) -> String {
        "c\(configurationRevision)-d\(descriptorRevision).bootstrap"
    }
    private func safe(_ value: String) -> Bool { !value.isEmpty && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }
    private func safeKey(_ value: String) -> Bool { value.range(of: "^c[1-9][0-9]*-d[1-9][0-9]*\\.bootstrap$", options: .regularExpression) != nil }
}

actor RemoteFirstStudyConfigurationProvider: StudyConfigurationProviding {
    private let remote: any RemoteStudyRepository
    private let cache: any StudyBootstrapCaching
    private let studyClients: any StudyBackendClientFactory
    private let environment: BackendEnvironment
    init(remote: any RemoteStudyRepository, cache: any StudyBootstrapCaching,
         studyClients: any StudyBackendClientFactory, environment: BackendEnvironment) {
        self.remote = remote; self.cache = cache; self.studyClients = studyClients; self.environment = environment
    }
    func configuration(for studyCode: String) async throws -> StudyConfiguration { try await resolvedStudy(for: studyCode).configuration }
    func resolvedStudy(for studyCode: String) async throws -> ResolvedStudy {
        let code = StudyCodeNormalizer.normalize(studyCode)
        do {
            let bootstrap = try await remote.resolveStudyBootstrap(studyCode: code)
            _ = try bootstrap.descriptor.validated(for: environment.name)
            let context = try await studyClients.context(for: bootstrap)
            let cacheKey = FileStudyBootstrapCache.cacheKey(configurationRevision: bootstrap.configurationRevision,
                                                             descriptorRevision: bootstrap.descriptor.revision)
            let resolved = ResolvedStudy(configuration: bootstrap.configuration, stableStudyID: bootstrap.stableStudyID,
                normalizedStudyCode: bootstrap.normalizedStudyCode,
                configurationSchemaVersion: bootstrap.configurationSchemaVersion,
                configurationRevision: bootstrap.configurationRevision, source: .remote,
                descriptor: bootstrap.descriptor, validatedIdentity: context.identity,
                controlEnvironment: environment.name, fetchedAt: bootstrap.fetchedAt, bootstrapCacheKey: cacheKey)
            try await cache.save(resolved); return resolved
        } catch let error as RemoteStudyError {
            guard error == .unavailable, environment.name != .production,
                  let cached = try await cache.latest(code: code, environment: environment.name) else { throw error }
            return cached
        }
    }
    func enrolledStudy(cacheKey: String, studyID: String, backendID: UUID) async throws -> ResolvedStudy? {
        try await cache.bootstrap(cacheKey: cacheKey, environment: environment.name, studyID: studyID, backendID: backendID)
    }
}
