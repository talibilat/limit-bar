import SwiftUI
import LimitBarCore

struct LimitBarSettingsView: View {
    private let storeHealth = StoredUsageMetrics.loadFromApplicationSupport().health

    var body: some View {
        Form {
            Section("Setup") {
                Text("Provider settings will be configured in a later issue.")
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Usage database", value: storeHealth.message)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420, height: 220)
    }
}

#Preview {
    LimitBarSettingsView()
}
