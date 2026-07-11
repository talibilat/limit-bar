import Foundation
import LimitBarCore

extension Notification.Name {
    static let providerSettingsDidChange = Notification.Name("limitbar.providerSettingsDidChange")
}

struct ProviderSettingsStore {
    static let storageKey = "limitbar.providerSettings"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: [ProviderSettings] {
        ProviderSettingsPersistence.decode(defaults.data(forKey: Self.storageKey))
    }

    func update(_ setting: ProviderSettings) {
        var updated = settings.filter { $0.provider != setting.provider }
        updated.append(setting)
        updated.sort { lhs, rhs in
            (ProviderKind.orderedCases.firstIndex(of: lhs.provider) ?? ProviderKind.orderedCases.endIndex)
                < (ProviderKind.orderedCases.firstIndex(of: rhs.provider) ?? ProviderKind.orderedCases.endIndex)
        }
        if let data = try? ProviderSettingsPersistence.encode(updated) {
            defaults.set(data, forKey: Self.storageKey)
            NotificationCenter.default.post(name: .providerSettingsDidChange, object: nil)
        }
    }
}
