# LimitBar Issue 7 Credentials And Diagnostics Design

## Context

Issue #7 adds the secure configuration layer required by the Anthropic and OpenAI provider slices.
LimitBar must represent provider authentication and connection health without writing secrets to UserDefaults, SQLite, diagnostics, exports, or UI state after save.
Saving a credential does not prove API access, so the app must distinguish configured credentials from a validated connection.

## Approved Approach

Define provider authentication, credential identifiers, connection states, and safe diagnostics in `LimitBarCore`.
Put credential access behind a narrow `CredentialStore` protocol and provide a macOS Keychain implementation.
Core tests use an in-memory fake and never access the user's Keychain.

Keep non-secret provider metadata separate from credentials.
The app may persist selected auth methods, Azure endpoint metadata, and safe connection states as JSON in UserDefaults.
Secret values are stored only as generic-password Keychain items under a dedicated LimitBar service name.

## Provider Authentication Model

Anthropic supports Admin API key and OAuth auth methods.
The Admin API key is usable by the next provider issue.
OAuth access and refresh token credential identifiers exist as an extension seam, but issue #7 does not implement an OAuth authorization flow.

Azure OpenAI supports an API key plus non-secret endpoint metadata.
The API key is stored in Keychain while the trimmed endpoint may be stored in provider settings.
The existing JSONL integration remains the usage source and does not begin calling Azure management APIs.

OpenAI supports OAuth and admin/platform credential methods.
Its settings model includes OAuth feasibility states of unvalidated, supported, unsupported, and admin credential required.
Issue #7 does not validate live OpenAI OAuth scopes; issue #9 will update feasibility after testing required usage access.

## Connection States

Provider state supports missing, configured, connected, failed, expired, unsupported, and admin required.
Missing means the selected method lacks required Keychain material.
Configured means required material is present but provider access has not been validated.
Connected is reserved for a successful provider validation or refresh.
Failed, expired, unsupported, and admin required carry predefined safe reasons rather than arbitrary raw provider text.

Saving a secret sets the provider to configured, not connected.
Clearing required credentials returns it to missing.
Later provider clients may publish validated states through the same model.

## Credential Storage

`CredentialStore` supports save, existence check, read, and delete operations using a `CredentialKey` composed of provider and credential kind.
The Keychain implementation uses `kSecClassGenericPassword`, a fixed LimitBar service identifier, and a stable account identifier derived from the credential key.
Saving replaces an existing item atomically from the caller's perspective.
Keychain status codes map to typed storage errors without embedding secret data.

The UI writes UTF-8 secret data to the store and clears its secure-field binding immediately after the operation finishes.
Settings never read a stored secret back into a text field.
Credential presence may be queried to render Missing or Configured.

## Safe Diagnostics

`ProviderDiagnostic` contains provider, connection state, timestamp, and an optional predefined safe failure reason.
Safe reasons cover authentication rejected, insufficient permissions, expired credential, invalid configuration, network unavailable, and refresh failed.
They expose stable user-facing summaries and never retain an underlying error, request, response, or credential.

`DiagnosticsReport` contains only provider diagnostics plus existing database and Azure JSONL health summaries.
Its encoded form is the future export contract.
Its type shape excludes API keys, access tokens, refresh tokens, prompts, responses, request bodies, terminal output, source code, and raw provider responses.

## Settings UI

Settings gains a Provider Authentication section above diagnostics.
Each provider has a compact disclosure group with auth-method controls, safe status text, and provider-specific fields.
Anthropic exposes Admin API key save/clear and an OAuth-compatible method state.
Azure exposes endpoint metadata plus API key save/clear.
OpenAI exposes OAuth feasibility and admin-required status without claiming a live OAuth connection.

Secret inputs use `SecureField` and never display saved values or masked values derived from the Keychain item.
Save actions are disabled for blank required input.
Clear actions remove Keychain material and update status to Missing.
Keychain failures render a generic safe message without status payloads or secret values.

## Persistence

`ProviderSettingsStore` persists only Codable non-secret settings in UserDefaults.
The persisted schema contains provider, selected auth method, Azure endpoint, OpenAI OAuth feasibility, connection state, safe reason, and update timestamp.
It contains no property capable of storing credential bytes or raw error payloads.

SQLite remains limited to normalized usage metrics.
No credential or provider-auth table is added.

## Error Handling

Duplicate Keychain saves replace the prior item.
Missing-item reads and deletes have explicit behavior.
Unexpected Keychain statuses become typed errors with generic descriptions.
Provider settings decoding failure falls back to safe default states without deleting Keychain items.
Diagnostics construction never interpolates secrets or raw provider responses.

## Testing

Core tests cover every auth method, connection state, OAuth feasibility state, and safe failure summary.
Credential service tests use an in-memory fake to cover save, replacement, existence, read, delete, configured-to-missing transitions, and failure propagation.
Diagnostics tests encode reports and assert forbidden fields and supplied secret sentinel values are absent.
Provider settings serialization tests prove only non-secret metadata is represented.
Native build verification covers Security framework linkage and SwiftUI provider settings compilation.
Manual QA for issue #10 will exercise real Keychain prompts and settings ergonomics.

## Out Of Scope

Live Anthropic usage refresh, a complete OAuth browser flow, OpenAI usage endpoint validation, Azure management APIs, credential export, encrypted credential backup, prompts, responses, raw provider response storage, and hosted diagnostics are out of scope.

## Acceptance Mapping

Provider auth models and settings cover Anthropic Admin API key/OAuth, Azure API key metadata, and OpenAI OAuth feasibility.
The Keychain adapter and fake-backed credential service cover secure storage and test isolation.
Structured connection states and safe diagnostics cover missing, connected, failed, expired, unsupported, and admin-required display.
The non-secret settings schema, diagnostics report shape, and SQLite schema tests enforce the privacy boundary.
