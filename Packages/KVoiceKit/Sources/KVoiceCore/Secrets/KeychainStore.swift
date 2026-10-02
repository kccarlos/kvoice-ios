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

    /// The Info.plist key holding the shared access group,
    /// `$(AppIdentifierPrefix)io.github.kccarlos.kvoice.ios.shared`.
    public static let accessGroupInfoKey = "KVoiceKeychainGroup"

    /// The store the app and the keyboard share: the access group from
    /// Info.plist when it is a real, team-prefixed group, else the default
    /// group (unsigned simulator builds).
    public static func shared(bundle: Bundle = .main) -> KeychainStore {
        KeychainStore(accessGroup: accessGroup(fromInfoValue: bundle.object(forInfoDictionaryKey: accessGroupInfoKey) as? String))
    }

    /// A usable access group from an Info.plist value, or nil when the
    /// build had no team (`$(AppIdentifierPrefix)` empty or unexpanded).
    public static func accessGroup(fromInfoValue value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.contains("$("),
              let dot = value.firstIndex(of: "."), dot != value.startIndex else { return nil }
        let prefix = value[..<dot]
        let suffix = value[value.index(after: dot)...]
        guard prefix.count == 10, prefix.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              !suffix.isEmpty else { return nil }
        return value
    }

    func service(for provider: ProviderKind) -> String {
        "\(servicePrefix).\(provider.rawValue)"
    }

    private func baseQuery(for provider: ProviderKind, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: provider),
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let group {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    /// Runs a Keychain operation with the access group, and again without
    /// it when the binary lacks the entitlement (unsigned builds).
    private func withGroupFallback(_ operation: (_ group: String?) -> OSStatus) -> OSStatus {
        let status = operation(accessGroup)
        if status == errSecMissingEntitlement, accessGroup != nil {
            return operation(nil)
        }
        return status
    }

    public func apiKey(for provider: ProviderKind) throws -> String? {
        var item: CFTypeRef?
        let status = withGroupFallback { group in
            var query = baseQuery(for: provider, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            item = nil
            return SecItemCopyMatching(query as CFDictionary, &item)
        }
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
        guard !trimmed.isEmpty else {
            let status = withGroupFallback { group in
                SecItemDelete(baseQuery(for: provider, group: group) as CFDictionary)
            }
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = withGroupFallback { group in
            let query = baseQuery(for: provider, group: group)
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            }
            return status
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
