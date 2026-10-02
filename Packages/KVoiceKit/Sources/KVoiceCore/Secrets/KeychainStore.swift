import Foundation
import Security
import Synchronization

/// Where API keys live. The production store is the Keychain; tests use
/// `InMemorySecretStore`. Keys are never written to defaults or files.
public protocol SecretStore: Sendable {
    func apiKey(for provider: ProviderKind) throws -> String?
    func setAPIKey(_ key: String?, for provider: ProviderKind) throws
}

public enum KeychainError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(message)"
        case .invalidData:
            return "The Keychain item could not be read."
        }
    }
}

/// Generic-password Keychain items, one service per provider, readable
/// after first unlock (so the keyboard can use them while the device is
/// locked after a restart has been unlocked once).
public struct KeychainStore: SecretStore {
    /// Prefix of every item's service name.
    public let servicePrefix: String
    /// Keychain access group shared by the app and the keyboard
    /// (`$(AppIdentifierPrefix)io.github...`), or nil for the default group.
    public let accessGroup: String?

    static let account = "apiKey"

    public init(servicePrefix: String = "io.github.kccarlos.kvoice.ios.apikey", accessGroup: String? = nil) {
        self.servicePrefix = servicePrefix
        self.accessGroup = accessGroup
    }

    func service(for provider: ProviderKind) -> String {
        "\(servicePrefix).\(provider.rawValue)"
    }

    private func baseQuery(for provider: ProviderKind) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: provider),
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func apiKey(for provider: ProviderKind) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Stores `key`, or deletes the item when `key` is nil or empty.
    public func setAPIKey(_ key: String?, for provider: ProviderKind) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = baseQuery(for: provider)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }
}

/// A process-local secret store for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let keys: Mutex<[ProviderKind: String]>

    public init(_ keys: [ProviderKind: String] = [:]) {
        self.keys = Mutex(keys)
    }

    public func apiKey(for provider: ProviderKind) throws -> String? {
        keys.withLock { $0[provider] }
    }

    public func setAPIKey(_ key: String?, for provider: ProviderKind) throws {
        keys.withLock { $0[provider] = (key?.isEmpty ?? true) ? nil : key }
    }
}
