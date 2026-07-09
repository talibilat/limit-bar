# LimitBar Issue 1 Bootstrap Design

## Context

Issue #1 bootstraps LimitBar as a private macOS 14+ menu bar utility.
The goal is to establish the native app shape and a testable core seam without introducing provider data, persistence, credentials, notifications, sounds, or urgent alerts.

## Approved Approach

Use a standard macOS SwiftUI app project named `LimitBar` plus a separate local Swift package named `LimitBarCore`.
The app target owns the native shell: `MenuBarExtra`, the popover shell, and the settings scene.
The core package owns only testable non-UI state needed by the shell.

This shape fits the issue acceptance criteria better than a SwiftPM-only app because it gives the project a normal native macOS app target from the start.
It also avoids a core-only bootstrap because issue #1 explicitly requires a running menu bar app surface.

## App Shell

The app will use SwiftUI and target macOS 14 or newer.
`LimitBarApp` will expose a compact menu bar item with the text `LimitBar` and a simple neutral status symbol.
Clicking the item will open a SwiftUI popover shell.
The popover shell will show a calm empty monitoring state that tells the user provider usage will appear in future issues.

The app will expose a native settings scene.
The settings shell will show an empty setup state rather than provider-specific configuration, because provider settings are out of scope until later issues.

## Core Package

`LimitBarCore` will include a minimal `AppStatus` model that describes the initial shell status shown by the app.
The model will be intentionally small so issue #2 can add normalized usage models and status rules without fighting premature abstractions.

The core package will have unit tests that verify the initial status label and symbol behavior used by the shell.
These tests prove the core package can run independently of the app target.

## Out Of Scope For Issue #1

Provider data is out of scope.
Persistence is out of scope.
Credential storage is out of scope.
Notifications, sounds, and urgent alerts are out of scope.
Cost calculation and quota status thresholds are out of scope until later issues.

## Testing And Verification

The core package will be verified with `swift test` from the `LimitBarCore` package directory.
The app target will be verified with `xcodebuild` against the generated macOS app scheme.
The README will document the exact local build and test commands for future agents.

## Acceptance Mapping

A macOS 14+ native app target exists through the generated Xcode project.
A separate testable core package exists through `LimitBarCore`.
Running the app shows a compact menu bar item through `MenuBarExtra`.
Clicking the menu bar item opens the SwiftUI popover shell.
The settings scene exposes a separate settings window from the native settings entry point.
The app does not include notification, sound, or alert APIs.
The README documents setup, build, and test commands.
