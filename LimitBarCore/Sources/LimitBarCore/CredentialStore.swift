import Foundation

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
