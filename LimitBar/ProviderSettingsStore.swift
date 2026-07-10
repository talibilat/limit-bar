import Foundation
import LimitBarCore

struct ProviderSettingsStore {
    static let storageKey = "limitbar.providerSettings"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: [ProviderSettings] {
        let stored: [ProviderSettings]
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ProviderSettings].self, from: data) {
            stored = decoded
        } else {
            stored = []
        }

        let byProvider = Dictionary(stored.map { ($0.provider, $0) }, uniquingKeysWith: { _, latest in latest })
        return ProviderKind.orderedCases.compactMap { provider in
            byProvider[provider] ?? ProviderSettings.defaultSettings.first { $0.provider == provider }
        }
    }

    func update(_ setting: ProviderSettings) {
        var updated = settings.filter { $0.provider != setting.provider }
        updated.append(setting)
        updated.sort { lhs, rhs in
            (ProviderKind.orderedCases.firstIndex(of: lhs.provider) ?? ProviderKind.orderedCases.endIndex)
                < (ProviderKind.orderedCases.firstIndex(of: rhs.provider) ?? ProviderKind.orderedCases.endIndex)
        }
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
