import SwiftUI
import LimitBarCore

@main
struct LimitBarApp: App {
    private let status = AppStatus.initial

    var body: some Scene {
        MenuBarExtra {
            MonitoringPopoverView()
        } label: {
            Label(status.menuBarText, systemImage: status.symbolName)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(status.accessibilityDescription)
        }
        .menuBarExtraStyle(.window)

        Settings {
            LimitBarSettingsView()
        }
    }
}
