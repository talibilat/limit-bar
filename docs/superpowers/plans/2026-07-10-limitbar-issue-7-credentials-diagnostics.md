# LimitBar Issue 7 Credentials And Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Keychain-only provider credential storage, non-secret provider settings, structured connection states, and redacted diagnostics for Anthropic, Azure OpenAI, and OpenAI.

**Architecture:** Define authentication and diagnostics types plus a credential-storage seam in `LimitBarCore`, with a Security-framework Keychain adapter and fake-backed tests. Persist only Codable non-secret provider settings in UserDefaults, then render provider-specific secure controls and structured diagnostics in the existing SwiftUI settings window.

**Tech Stack:** Swift 6, Foundation, Security.framework, Swift Testing, SwiftUI, UserDefaults JSON, macOS 14+.

## Global Constraints

- Secrets are stored only as generic-password items in macOS Keychain.
- Saving credentials produces Configured, not Connected, until a provider validator succeeds.
- Settings never read saved secret bytes back into a text field.
- UserDefaults, SQLite, diagnostics, and encoded reports contain no API keys, access tokens, refresh tokens, prompts, responses, request bodies, terminal output, source code, or raw provider responses.
- Tests use an in-memory credential store and never access the user's Keychain.
- Live provider refresh, OAuth browser flows, and Azure management APIs remain out of scope.

---

## File Structure

- Create `LimitBarCore/Sources/LimitBarCore/ProviderAuthentication.swift` for auth methods, connection states, OAuth feasibility, non-secret provider settings, safe diagnostics, and diagnostics reports.
- Create `LimitBarCore/Tests/LimitBarCoreTests/ProviderAuthenticationTests.swift` for model, serialization, and redaction behavior.
- Create `LimitBarCore/Sources/LimitBarCore/CredentialStore.swift` for credential keys, the storage protocol, credential service, typed errors, and the Keychain implementation.
- Create `LimitBarCore/Tests/LimitBarCoreTests/CredentialStoreTests.swift` with an in-memory fake.
- Modify `LimitBarCore/Package.swift` to link Security.framework.
- Create `LimitBar/ProviderSettingsStore.swift` for UserDefaults persistence of only non-secret provider settings.
- Create `LimitBar/ProviderSettingsView.swift` for provider-specific secure controls.
- Modify `LimitBar/LimitBarSettingsView.swift` to replace the placeholder Setup section and render structured provider diagnostics.
- Modify `LimitBar.xcodeproj/project.pbxproj` to compile the two new app files.

### Task 1: Provider Authentication And Safe Diagnostics Model

**Files:**
- Create: `LimitBarCore/Sources/LimitBarCore/ProviderAuthentication.swift`
- Create: `LimitBarCore/Tests/LimitBarCoreTests/ProviderAuthenticationTests.swift`

**Interfaces:**
- Produces: `ProviderAuthMethod`, `ProviderConnectionState`, `OpenAIOAuthFeasibility`, `ProviderFailureReason`, `ProviderSettings`, `ProviderDiagnostic`, and `DiagnosticsReport`.

- [ ] **Step 1: Write failing model and redaction tests**

Cover exact provider-method compatibility:

```swift
#expect(ProviderAuthMethod.anthropicAdminAPIKey.provider == .anthropic)
#expect(ProviderAuthMethod.anthropicOAuth.provider == .anthropic)
#expect(ProviderAuthMethod.azureAPIKey.provider == .azureOpenAI)
#expect(ProviderAuthMethod.openAIOAuth.provider == .openAI)
#expect(ProviderAuthMethod.openAIAdminAPIKey.provider == .openAI)
```

Assert all states have stable display text, `.configured` does not display Connected, OAuth feasibility covers unvalidated/supported/unsupported/admin-required, and defaults exist in fixed provider order. Build a report with the sentinel `super-secret-value` supplied only outside the report, encode it, and assert the JSON contains provider/status summaries but not the sentinel or forbidden key names `apiKey`, `accessToken`, `refreshToken`, `prompt`, `response`, `terminalOutput`, `sourceCode`, or `rawProviderResponse`.

- [ ] **Step 2: Run the focused test and verify failure**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter ProviderAuthenticationTests`

Expected: FAIL because the provider authentication types do not exist.

- [ ] **Step 3: Implement the non-secret model**

Define string-backed Codable enums with these cases:

```swift
public enum ProviderConnectionState: String, Codable, CaseIterable, Sendable {
    case missing, configured, connected, failed, expired, unsupported, adminRequired
}

public enum OpenAIOAuthFeasibility: String, Codable, CaseIterable, Sendable {
    case unvalidated, supported, unsupported, adminCredentialRequired
}

public enum ProviderFailureReason: String, Codable, CaseIterable, Sendable {
    case authenticationRejected, insufficientPermissions, expiredCredential
    case invalidConfiguration, networkUnavailable, refreshFailed
}
```

`ProviderSettings` contains only provider, auth method, optional Azure endpoint, OpenAI feasibility, state, optional safe failure reason, and `updatedAt`. Add `defaultSettings` in provider order. `ProviderDiagnostic` mirrors only provider, state, safe reason, and timestamp. `DiagnosticsReport` contains `[ProviderDiagnostic]`, usage database summary, Azure accepted/rejected counts, and optional safe Azure failure summary.

- [ ] **Step 4: Run focused and full core tests**

Run the focused command, then `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore`.

Expected: all tests PASS.

- [ ] **Step 5: Commit the model slice**

```bash
git add LimitBarCore/Sources/LimitBarCore/ProviderAuthentication.swift LimitBarCore/Tests/LimitBarCoreTests/ProviderAuthenticationTests.swift
git commit -m "Model provider authentication diagnostics"
```

### Task 2: Credential Store Seam And Service

**Files:**
- Create: `LimitBarCore/Sources/LimitBarCore/CredentialStore.swift`
- Create: `LimitBarCore/Tests/LimitBarCoreTests/CredentialStoreTests.swift`

**Interfaces:**
- Produces: `CredentialKind`, `CredentialKey`, `CredentialStore`, `CredentialStoreError`, and `CredentialService`.

- [ ] **Step 1: Write failing fake-backed service tests**

Define a private in-memory fake in the test file and test save/read/replacement/existence/delete without real Keychain access:

```swift
let key = CredentialKey(provider: .anthropic, kind: .apiKey)
let fake = InMemoryCredentialStore()
let service = CredentialService(store: fake)
try service.save("first", for: key)
try service.save("second", for: key)
#expect(try service.hasCredential(for: key))
#expect(try service.credential(for: key) == Data("second".utf8))
try service.removeCredential(for: key)
#expect(!(try service.hasCredential(for: key)))
```

Assert blank secrets throw `.emptyCredential`, missing reads return `nil`, missing deletes succeed, storage failures propagate as generic typed errors, and stable account identifiers differ for every provider/kind pair.

- [ ] **Step 2: Run focused tests and verify failure**

Run: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore --filter CredentialStoreTests`

Expected: FAIL because credential interfaces do not exist.

- [ ] **Step 3: Implement the credential seam**

Define:

```swift
public protocol CredentialStore: Sendable {
    func save(_ data: Data, for key: CredentialKey) throws
    func data(for key: CredentialKey) throws -> Data?
    func contains(_ key: CredentialKey) throws -> Bool
    func remove(_ key: CredentialKey) throws
}

public struct CredentialService: Sendable {
    public let store: any CredentialStore
    public func save(_ secret: String, for key: CredentialKey) throws
    public func credential(for key: CredentialKey) throws -> Data?
    public func hasCredential(for key: CredentialKey) throws -> Bool
    public func removeCredential(for key: CredentialKey) throws
}
```

Trim only to test blank input; preserve the user's original secret bytes when nonblank. Do not add `CustomStringConvertible` for credential data or errors containing payloads.

- [ ] **Step 4: Run focused and full tests**

Run the CredentialStore filter and full core suite.

Expected: all tests PASS.

- [ ] **Step 5: Commit the seam**

```bash
git add LimitBarCore/Sources/LimitBarCore/CredentialStore.swift LimitBarCore/Tests/LimitBarCoreTests/CredentialStoreTests.swift
git commit -m "Add credential storage seam"
```

### Task 3: macOS Keychain Adapter

**Files:**
- Modify: `LimitBarCore/Sources/LimitBarCore/CredentialStore.swift`
- Modify: `LimitBarCore/Package.swift`
- Modify: `LimitBarCore/Tests/LimitBarCoreTests/CredentialStoreTests.swift`

**Interfaces:**
- Consumes: `CredentialStore` and stable `CredentialKey.accountIdentifier`.
- Produces: `KeychainCredentialStore` using service `com.talibilat.LimitBar.credentials`.

- [ ] **Step 1: Add failing adapter-shape tests**

Assert `KeychainCredentialStore.service == "com.talibilat.LimitBar.credentials"` and that it conforms to `CredentialStore` through a compile-time helper. Do not execute save/read/delete in tests.

- [ ] **Step 2: Run the focused test and verify failure**

Run the CredentialStore filter.

Expected: FAIL because `KeychainCredentialStore` does not exist.

- [ ] **Step 3: Implement Security-framework operations**

Link `.linkedFramework("Security")` in the core target. Implement generic-password queries using service plus account. Save first calls `SecItemUpdate`; when status is `errSecItemNotFound`, call `SecItemAdd`. Read requests one data result. Contains uses a non-returning match query. Remove treats `errSecItemNotFound` as success. Map all other statuses to `CredentialStoreError.keychainFailure(operation:)` where operation is a fixed safe enum, never the OS status text or secret data.

- [ ] **Step 4: Run full core tests and native build**

Run the full core suite and native build command.

Expected: tests PASS and `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit the adapter**

```bash
git add LimitBarCore/Sources/LimitBarCore/CredentialStore.swift LimitBarCore/Package.swift LimitBarCore/Tests/LimitBarCoreTests/CredentialStoreTests.swift
git commit -m "Store provider secrets in Keychain"
```

### Task 4: Non-Secret Provider Settings Persistence

**Files:**
- Create: `LimitBar/ProviderSettingsStore.swift`
- Modify: `LimitBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ProviderSettings.defaultSettings`.
- Produces: `ProviderSettingsStore.settings`, `update(_:)`, and JSON-backed `UserDefaults` persistence under `limitbar.providerSettings`.

- [ ] **Step 1: Implement the narrow settings adapter**

Follow `PricingSettingsStore` conventions. Decode `[ProviderSettings]`, merge missing providers from defaults, sort by `ProviderKind.orderedCases`, and fall back to defaults on invalid JSON. `update(_:)` replaces only the matching provider and writes encoded JSON. The file must contain no secret-taking API.

- [ ] **Step 2: Add the source file to the Xcode project**

Add one PBX file reference, build file, group child, and Sources phase entry for `ProviderSettingsStore.swift` using new stable IDs.

- [ ] **Step 3: Build the app**

Run the native build command.

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit settings persistence**

```bash
git add LimitBar/ProviderSettingsStore.swift LimitBar.xcodeproj/project.pbxproj
git commit -m "Persist non-secret provider settings"
```

### Task 5: Provider Authentication Settings UI

**Files:**
- Create: `LimitBar/ProviderSettingsView.swift`
- Modify: `LimitBar/LimitBarSettingsView.swift`
- Modify: `LimitBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ProviderSettingsStore`, `CredentialService`, `KeychainCredentialStore`, credential keys, and provider settings model.
- Produces: `ProviderSettingsView` and provider diagnostics shown in settings.

- [ ] **Step 1: Build provider-specific secure controls**

Create a view with one disclosure group per provider in fixed order. Use `SecureField` for Anthropic Admin API key, Azure API key, and OpenAI admin/platform API key. Use provider-filtered auth-method pickers, an Azure endpoint `TextField`, and read-only OpenAI OAuth feasibility copy. Keep separate `@State` secret strings and never initialize them from Keychain.

Save handlers must:

```swift
defer { enteredSecret = "" }
try credentialService.save(enteredSecret, for: credentialKey)
settings.state = .configured
settings.failureReason = nil
settings.updatedAt = Date()
settingsStore.update(settings)
```

Clear handlers remove the credential, clear the secure field, set `.missing`, and persist. Blank secrets disable Save. Generic UI errors are exactly `Could not update Keychain.` and contain no underlying error interpolation.

- [ ] **Step 2: Integrate settings and diagnostics**

Replace the placeholder Setup section in `LimitBarSettingsView` with `Section("Provider Authentication") { ProviderSettingsView() }`. In Diagnostics, render one labeled row per provider using persisted structured state and safe reason summary before existing database and Azure diagnostics.

- [ ] **Step 3: Add the view to the Xcode project**

Add the PBX reference/build/group/source entries for `ProviderSettingsView.swift`.

- [ ] **Step 4: Build and run all core tests**

Run the native build and full core suite.

Expected: build succeeds and all tests PASS.

- [ ] **Step 5: Commit UI integration**

```bash
git add LimitBar/ProviderSettingsView.swift LimitBar/LimitBarSettingsView.swift LimitBar.xcodeproj/project.pbxproj
git commit -m "Add secure provider settings"
```

### Task 6: Privacy And Delivery Verification

**Files:**
- Modify only files required by verified defects.

- [ ] **Step 1: Run privacy searches**

Search tracked source and schema changes for accidental secret persistence fields. Inspect `git diff main...HEAD` and confirm UserDefaults Codable models, SQLite columns, diagnostics, and UI display paths contain no credential values or raw provider errors.

- [ ] **Step 2: Run full verification**

Run the full core test suite, native build, and `git diff --check main...HEAD`.

Expected: all tests PASS, build succeeds, and no whitespace errors appear.

- [ ] **Step 3: Review the complete branch**

Request independent review against issue #7 and this plan. Fix every Critical or Important finding with a failing regression test where behavior is testable, then repeat Step 2.

- [ ] **Step 4: Deliver through GitHub**

Push the branch to `origin`, create a PR with `Closes #7`, inspect checks and mergeability, merge after clean verification, and confirm issue #7 closes.

## Self-Review

- Spec coverage: auth methods, all connection states, OAuth feasibility, Keychain-only secrets, fake-backed tests, non-secret settings, safe diagnostics, UI clearing, and privacy exports map to explicit tasks.
- Placeholder scan: no incomplete implementation markers remain.
- Type consistency: provider settings, credential service, Keychain adapter, settings store, and diagnostics names are consistent across tasks.
- Scope check: live refresh and OAuth flows remain in issues #8 and #9.
