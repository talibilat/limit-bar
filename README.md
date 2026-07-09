# LimitBar

LimitBar is a private macOS 14+ menu bar utility for monitoring AI provider usage.

## Project Layout

- `LimitBar.xcodeproj` contains the native macOS SwiftUI app target.
- `LimitBar` contains the menu bar app shell, monitoring popover, and settings shell.
- `LimitBarCore` contains testable core code that does not depend on SwiftUI.

## Requirements

- macOS 14 or newer.
- Full Xcode for native app builds with `xcodebuild`.
- Swift 6 command line tools for core package tests.

## Test Core Package

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test --package-path LimitBarCore
```

## Build Native App

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -destination 'platform=macOS' build
```

## Run The App

Open `LimitBar.xcodeproj` in Xcode and run the `LimitBar` scheme.
The app appears as a compact menu bar item and opens the monitoring popover from the menu bar.

## Issue #1 Scope

This bootstrap does not add provider integrations, persistence, credentials, notifications, sounds, or urgent alerts.
