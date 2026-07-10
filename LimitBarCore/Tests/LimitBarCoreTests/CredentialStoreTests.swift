import Foundation
import Testing
@testable import LimitBarCore

@Suite("Credential store")
struct CredentialStoreTests {
    @Test("credential service saves replaces reads and removes secrets")
    func credentialServiceLifecycle() throws {
        let key = CredentialKey(provider: .anthropic, kind: .apiKey)
        let fake = InMemoryCredentialStore()
        let service = CredentialService(store: fake)

        try service.save("first", for: key)
        try service.save("second", for: key)

        #expect(try service.hasCredential(for: key))
        #expect(try service.credential(for: key) == Data("second".utf8))
        try service.removeCredential(for: key)
        #expect(!(try service.hasCredential(for: key)))
        #expect(try service.credential(for: key) == nil)
        try service.removeCredential(for: key)
    }

    @Test("blank credentials are rejected without changing storage")
    func blankCredentialsAreRejected() throws {
        let key = CredentialKey(provider: .azureOpenAI, kind: .apiKey)
        let fake = InMemoryCredentialStore()
        let service = CredentialService(store: fake)

        #expect(throws: CredentialStoreError.emptyCredential) {
            try service.save("  \n", for: key)
        }
        #expect(!(try service.hasCredential(for: key)))
    }

    @Test("nonblank credential bytes are preserved exactly")
    func nonblankCredentialBytesArePreservedExactly() throws {
        let key = CredentialKey(provider: .openAI, kind: .accessToken)
        let fake = InMemoryCredentialStore()
        let service = CredentialService(store: fake)

        try service.save("  token-with-spaces  ", for: key)

        #expect(try service.credential(for: key) == Data("  token-with-spaces  ".utf8))
    }

    @Test("storage failures propagate without secret payloads")
    func storageFailuresPropagate() {
        let key = CredentialKey(provider: .openAI, kind: .refreshToken)
        let fake = InMemoryCredentialStore(error: .storageFailure)
        let service = CredentialService(store: fake)

        #expect(throws: CredentialStoreError.storageFailure) {
            try service.save("super-secret-value", for: key)
        }
    }

    @Test("credential account identifiers are stable and unique")
    func credentialAccountIdentifiersAreStableAndUnique() {
        let keys = ProviderKind.allCases.flatMap { provider in
            CredentialKind.allCases.map { CredentialKey(provider: provider, kind: $0) }
        }

        #expect(Set(keys.map(\.accountIdentifier)).count == keys.count)
        #expect(CredentialKey(provider: .anthropic, kind: .apiKey).accountIdentifier == "anthropic.apiKey")
    }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [CredentialKey: Data] = [:]
    private let error: CredentialStoreError?

    init(error: CredentialStoreError? = nil) {
        self.error = error
    }

    func save(_ data: Data, for key: CredentialKey) throws {
        if let error { throw error }
        values[key] = data
    }

    func data(for key: CredentialKey) throws -> Data? {
        if let error { throw error }
        return values[key]
    }

    func contains(_ key: CredentialKey) throws -> Bool {
        if let error { throw error }
        return values[key] != nil
    }

    func remove(_ key: CredentialKey) throws {
        if let error { throw error }
        values.removeValue(forKey: key)
    }
}
