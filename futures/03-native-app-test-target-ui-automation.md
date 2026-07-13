# Native App Test Target And UI Automation

## Status

Implemented on the `ticket-03-native-ui-tests` branch.

## Outcome

The repository has an app-hosted integration-test target and a UI-test target.
The tests cover app bootstrap through production popover content, the passive Claude Authorization Required state, the Connect Action, and Custom Usage Source configuration.

## Automated Boundary

`LimitBarTests` verifies app-owned Custom Usage Source persistence with an isolated UserDefaults suite.
`LimitBarUITests` launches the real app executable and hosts production popover or Custom Usage Source content in a deterministic test window.
UI-test dependencies use generated temporary files, isolated UserDefaults, synthetic Claude state, and disabled local refresh.
They do not read production SQLite, provider settings, Keychain, Codex sessions, or network resources.
Fixture implementations compile only in Debug builds.

## Explicit Non-Goals

Automation does not validate the real menu bar status item, macOS Keychain dialogs, signed identity behavior, Finder interaction, provider production systems, or real accounts.
Those remain manual or signed-account QA.

## Privacy And Security

Fixtures contain only generated identifiers, temporary paths, and synthetic metrics.
They contain no credentials, prompts, code, responses, terminal output, or provider payloads.

## Verification

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  xcodebuild \
  -project LimitBar.xcodeproj \
  -scheme LimitBar \
  -destination 'platform=macOS' \
  test
```

The terminal or CI agent launching UI tests must have macOS Developer Tools permission.
Test the minimum supported macOS release and newest stable supported release before distribution.

## Exit Criteria

- The app integration tests pass from a clean checkout.
- UI automation executes on a host with Developer Tools permission.
- Automation covers launch content, passive Claude authorization presentation, Connect, and Custom Usage Source add, relaunch, and removal.
- Tests require no real account or credential material.
- Release builds contain no test-fixture behavior.
