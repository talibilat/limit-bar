import SwiftUI

struct LimitBarSettingsView: View {
    var body: some View {
        Form {
            Section("Setup") {
                Text("Provider settings will be configured in a later issue.")
                    .foregroundStyle(.secondary)
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
