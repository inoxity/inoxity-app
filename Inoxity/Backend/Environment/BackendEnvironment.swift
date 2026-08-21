import Foundation

enum BackendEnvironmentName: String, Codable, CaseIterable, Sendable { case development = "Development", staging = "Staging", production = "Production" }

struct BackendEnvironment: Equatable, Sendable {
    let name: BackendEnvironmentName
    let supabaseURL: URL
    let supabaseAnonKey: String
    var allowsProvisionalEnrollment: Bool { name != .production }
    var authStorageNamespace: String { "inoxity.control.\(name.rawValue.lowercased())" }

    init(name: BackendEnvironmentName, supabaseURL: URL, supabaseAnonKey: String) throws {
        guard supabaseURL.scheme == "https", supabaseURL.host != nil else { throw BackendError.malformedURL }
        guard !supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !supabaseAnonKey.contains("REPLACE_ME") else { throw BackendError.missingConfiguration }
        self.name = name; self.supabaseURL = supabaseURL; self.supabaseAnonKey = supabaseAnonKey
    }
}

protocol BackendEnvironmentLoading: Sendable { func load() throws -> BackendEnvironment }

struct InfoPlistBackendEnvironmentLoader: BackendEnvironmentLoading, Sendable {
    private let values: [String: String]
    init(bundle: Bundle = .main) {
        values = ["INOXITY_ENVIRONMENT", "INOXITY_CONTROL_SUPABASE_URL", "INOXITY_CONTROL_SUPABASE_ANON_KEY", "SUPABASE_URL", "SUPABASE_ANON_KEY"].reduce(into: [:]) {
            $0[$1] = bundle.object(forInfoDictionaryKey: $1) as? String
        }
    }
    init(values: [String: String]) { self.values = values }
    func load() throws -> BackendEnvironment {
        guard let rawName = values["INOXITY_ENVIRONMENT"],
              let name = BackendEnvironmentName.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(rawName) == .orderedSame }),
              let rawURL = values["INOXITY_CONTROL_SUPABASE_URL"] ?? (name == .production ? nil : values["SUPABASE_URL"]),
              let url = URL(string: rawURL),
              let key = values["INOXITY_CONTROL_SUPABASE_ANON_KEY"] ?? (name == .production ? nil : values["SUPABASE_ANON_KEY"]) else { throw BackendError.missingConfiguration }
        return try BackendEnvironment(name: name, supabaseURL: url, supabaseAnonKey: key)
    }
}
