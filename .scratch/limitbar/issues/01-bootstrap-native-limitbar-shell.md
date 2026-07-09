# Bootstrap LimitBar As A Native macOS Menu Bar App

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Create the initial native macOS 14+ LimitBar application shell.
The app should appear as a menu bar utility, open a monitoring popover, and expose a separate settings window.
This issue establishes the product shape and project structure without requiring real provider data.

The implementation should include a testable core package, a macOS app target, a minimal app model, a menu bar item, an empty popover shell, an empty settings shell, and documented build/test commands.
The user-visible result is a running Mac menu bar app that feels like the foundation of LimitBar rather than a command-line prototype.

## Acceptance criteria

- [ ] A macOS 14+ native app target exists and builds locally.
- [ ] A separate testable core package exists and can run its tests independently.
- [ ] Running the app shows a compact LimitBar item in the macOS menu bar.
- [ ] Clicking the menu bar item opens a SwiftUI popover window.
- [ ] The app exposes a separate settings window from the native settings entry point.
- [ ] The app does not send notifications, play sounds, or show urgent alerts.
- [ ] Local setup commands are documented so another agent can build and test the project.

## Blocked by

None - can start immediately.
