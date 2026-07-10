import Foundation
import Security
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

    @Test("Keychain adapter uses the dedicated service and storage seam")
    func keychainAdapterShape() {
        let store: any CredentialStore = KeychainCredentialStore()

        #expect(KeychainCredentialStore.service == "com.talibilat.LimitBar.credentials")
        _ = store
    }

    @Test("Keychain save retries update after a concurrent duplicate add")
    func keychainSaveRetriesConcurrentDuplicate() throws {
        let operations = FakeKeychainOperations(
            updateStatuses: [errSecItemNotFound, errSecSuccess],
            addStatuses: [errSecDuplicateItem]
        )
        let store = KeychainCredentialStore(operations: operations)

        try store.save(Data("secret".utf8), for: CredentialKey(provider: .anthropic, kind: .apiKey))

        #expect(operations.updateCallCount == 2)
        #expect(operations.addCallCount == 1)
    }

    @Test("credential reconciliation downgrades missing items and preserves validated states")
    func credentialReconciliationUsesActualPresence() throws {
        let fake = InMemoryCredentialStore()
        let reconciler = ProviderCredentialStateReconciler(credentialService: CredentialService(store: fake))
        var connected = ProviderSettings.defaultSettings[0]
        connected.state = .connected

        let missing = try reconciler.reconcile(connected)
        #expect(missing.state == .missing)

        try fake.save(Data("secret".utf8), for: CredentialKey(provider: .anthropic, kind: .apiKey))
        let retained = try reconciler.reconcile(connected)
        #expect(retained.state == .connected)

        var initiallyMissing = connected
        initiallyMissing.state = .missing
        let configured = try reconciler.reconcile(initiallyMissing)
        #expect(configured.state == .configured)
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

private final class FakeKeychainOperations: KeychainOperations, @unchecked Sendable {
    private var updateStatuses: [OSStatus]
    private var addStatuses: [OSStatus]
    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0

    init(updateStatuses: [OSStatus], addStatuses: [OSStatus]) {
        self.updateStatuses = updateStatuses
        self.addStatuses = addStatuses
    }

    func update(_ data: Data, service: String, account: String) -> OSStatus {
        updateCallCount += 1
        return updateStatuses.removeFirst()
    }

    func add(_ data: Data, service: String, account: String) -> OSStatus {
        addCallCount += 1
        return addStatuses.removeFirst()
    }

    func read(service: String, account: String) -> (OSStatus, Data?) {
        (errSecItemNotFound, nil)
    }

    func contains(service: String, account: String) -> OSStatus {
        errSecItemNotFound
    }

    func remove(service: String, account: String) -> OSStatus {
        errSecItemNotFound
    }
}
