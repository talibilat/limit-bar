import SwiftUI
import LimitBarCore

@main
struct LimitBarApp: App {
    var body: some Scene {
        MenuBarExtra {
            MonitoringPopoverView()
        } label: {
            MenuBarStatusLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            LimitBarSettingsView()
        }
    }
}

private struct MenuBarStatusLabel: View {
    @State private var status = AppStatus.initial

    var body: some View {
        Label(status.menuBarText, systemImage: status.symbolName)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(statusColor)
            .accessibilityLabel(status.accessibilityDescription)
            .task { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: .providerSettingsDidChange)) { _ in
                Task { await reload() }
            }
    }

    private func reload() async {
        let snapshot = await StoredUsageMetricsLoader.shared.loadFromApplicationSupport()
        status = AppStatus.from(menuBarStatus: MenuBarStatus.from(metrics: snapshot.metrics))
    }

    private var statusColor: Color {
        switch status.statusColor {
        case .green:
            .green
        case .yellow:
            .yellow
        case .red:
            .red
        case .gray:
            .secondary
        }
    }
}
