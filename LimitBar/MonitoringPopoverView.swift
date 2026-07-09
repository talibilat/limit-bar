import SwiftUI

struct MonitoringPopoverView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LimitBar")
                    .font(.title2.weight(.semibold))
                Text("Provider usage will appear here as integrations are added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("No provider data configured yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                SettingsLink {
                    Text("Settings")
                }
            }
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
    }
}

#Preview {
    MonitoringPopoverView()
}
