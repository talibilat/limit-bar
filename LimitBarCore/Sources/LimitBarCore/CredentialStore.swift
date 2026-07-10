import Foundation
import Security

public enum CredentialKind: String, Codable, CaseIterable, Equatable, Sendable {
    case apiKey
    case accessToken
    case refreshToken
}

public struct CredentialKey: Codable, Equatable, Hashable, Sendable {
    public let provider: ProviderKind
    public let kind: CredentialKind

    public init(provider: ProviderKind, kind: CredentialKind) {
        self.provider = provider
        self.kind = kind
    }

    public var accountIdentifier: String {
        "\(provider.rawValue).\(kind.rawValue)"
    }
}

public enum KeychainOperation: String, Equatable, Sendable {
    case save
    case read
    case contains
    case remove
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case emptyCredential
    case storageFailure
    case keychainFailure(operation: KeychainOperation)
}

public protocol CredentialStore: Sendable {
    func save(_ data: Data, for key: CredentialKey) throws
    func data(for key: CredentialKey) throws -> Data?
    func contains(_ key: CredentialKey) throws -> Bool
    func remove(_ key: CredentialKey) throws
}

public struct CredentialService: Sendable {
    public let store: any CredentialStore

    public init(store: any CredentialStore) {
        self.store = store
    }

    public func save(_ secret: String, for key: CredentialKey) throws {
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CredentialStoreError.emptyCredential
        }
        try store.save(Data(secret.utf8), for: key)
    }

    public func credential(for key: CredentialKey) throws -> Data? {
        try store.data(for: key)
    }

    public func hasCredential(for key: CredentialKey) throws -> Bool {
        try store.contains(key)
    }

    public func removeCredential(for key: CredentialKey) throws {
        try store.remove(key)
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public static let service = "com.talibilat.LimitBar.credentials"

    public init() {}

    public func save(_ data: Data, for key: CredentialKey) throws {
        let query = baseQuery(for: key)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(operation: .save)
        }
    }

    public func data(for key: CredentialKey) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.keychainFailure(operation: .read)
        }
        return data
    }

    public func contains(_ key: CredentialKey) throws -> Bool {
        var query = baseQuery(for: key)
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(operation: .contains)
        }
        return true
    }

    public func remove(_ key: CredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(operation: .remove)
        }
    }

    private func baseQuery(for key: CredentialKey) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: key.accountIdentifier
        ]
    }
}
