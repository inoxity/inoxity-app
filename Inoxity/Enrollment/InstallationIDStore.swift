import Foundation
import Security

protocol InstallationIdentifying: Sendable { func installationID() async throws -> UUID }

protocol InstallationIDSecureStoring: Sendable {
    func read() async throws -> String?
    func write(_ value: String) async throws
    func remove() async throws
}
actor KeychainInstallationIDStore: InstallationIdentifying {
    private let secureStore: any InstallationIDSecureStoring
    private let marker: InstallationMarkerStoring
    private var cached: UUID?
    init(secureStore: any InstallationIDSecureStoring = KeychainStringStore(), marker: InstallationMarkerStoring = UserDefaultsInstallationMarker()) {
        self.secureStore = secureStore; self.marker = marker
    }
    func installationID() async throws -> UUID {
        if let cached { return cached }
        if !marker.exists {
            try await secureStore.remove(); marker.exists = true
        }
        if let raw = try await secureStore.read(), let existing = UUID(uuidString: raw) { cached = existing; return existing }
        let value = UUID(); try await secureStore.write(value.uuidString.lowercased()); cached = value; return value
    }
}

protocol InstallationMarkerStoring: AnyObject { var exists: Bool { get set } }
final class UserDefaultsInstallationMarker: InstallationMarkerStoring {
    private let defaults: UserDefaults; private let key = "installation.marker.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var exists: Bool { get { defaults.bool(forKey: key) } set { defaults.set(newValue, forKey: key) } }
}

actor KeychainStringStore: InstallationIDSecureStoring {
    private let service = "org.cogcommscience.Inoxity.installation"; private let account = "installation-id"
    func read() throws -> String? {
        var query: [String: Any] = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw BackendError.unavailable }
        return value
    }
    func write(_ value: String) throws {
        let data = Data(value.utf8); let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw BackendError.unavailable }
        } else if status != errSecSuccess { throw BackendError.unavailable }
    }
    func remove() throws { let status = SecItemDelete(base as CFDictionary); if status != errSecSuccess && status != errSecItemNotFound { throw BackendError.unavailable } }
    private var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
}
