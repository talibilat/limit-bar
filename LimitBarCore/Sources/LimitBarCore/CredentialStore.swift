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

public struct ProviderCredentialStateReconciler: Sendable {
    public let credentialService: CredentialService

    public init(credentialService: CredentialService) {
        self.credentialService = credentialService
    }

    public func reconcile(_ settings: ProviderSettings, authMethodChanged: Bool = false) throws -> ProviderSettings {
        var reconciled = settings
        let key = CredentialKey(provider: settings.provider, kind: settings.authMethod.credentialKind)
        if try credentialService.hasCredential(for: key) {
            if authMethodChanged || reconciled.state == .missing {
                reconciled.state = .configured
                reconciled.failureReason = nil
            }
        } else {
            reconciled.state = .missing
            reconciled.failureReason = nil
        }
        return reconciled
    }
}

protocol KeychainOperations: Sendable {
    func update(_ data: Data, service: String, account: String) -> OSStatus
    func add(_ data: Data, service: String, account: String) -> OSStatus
    func read(service: String, account: String) -> (OSStatus, Data?)
    func contains(service: String, account: String) -> OSStatus
    func remove(service: String, account: String) -> OSStatus
}

private struct SecurityKeychainOperations: KeychainOperations {
    func update(_ data: Data, service: String, account: String) -> OSStatus {
        SecItemUpdate(baseQuery(service: service, account: account) as CFDictionary, [kSecValueData: data] as CFDictionary)
    }

    func add(_ data: Data, service: String, account: String) -> OSStatus {
        var item = baseQuery(service: service, account: account)
        item[kSecValueData] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    func read(service: String, account: String) -> (OSStatus, Data?) {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func contains(service: String, account: String) -> OSStatus {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    func remove(service: String, account: String) -> OSStatus {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private func baseQuery(service: String, account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public static let service = "com.talibilat.LimitBar.credentials"
    private let operations: any KeychainOperations

    public init() {
        operations = SecurityKeychainOperations()
    }

    init(operations: any KeychainOperations) {
        self.operations = operations
    }

    public func save(_ data: Data, for key: CredentialKey) throws {
        var status = operations.update(data, service: Self.service, account: key.accountIdentifier)
        if status == errSecItemNotFound {
            status = operations.add(data, service: Self.service, account: key.accountIdentifier)
            if status == errSecDuplicateItem {
                status = operations.update(data, service: Self.service, account: key.accountIdentifier)
            }
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(operation: .save)
        }
    }

    public func data(for key: CredentialKey) throws -> Data? {
        let (status, result) = operations.read(service: Self.service, account: key.accountIdentifier)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result else {
            throw CredentialStoreError.keychainFailure(operation: .read)
        }
        return data
    }

    public func contains(_ key: CredentialKey) throws -> Bool {
        let status = operations.contains(service: Self.service, account: key.accountIdentifier)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(operation: .contains)
        }
        return true
    }

    public func remove(_ key: CredentialKey) throws {
        let status = operations.remove(service: Self.service, account: key.accountIdentifier)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(operation: .remove)
        }
    }

}
