import Foundation

extension Notification.Name {
    static let localRefreshSettingsDidChange = Notification.Name("LimitBar.localRefreshSettingsDidChange")
}

enum LocalRefreshCadence: Int, CaseIterable, Codable {
    case fiveSeconds = 5
    case fifteenSeconds = 15
    case thirtySeconds = 30

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var displayName: String {
        "Every \(rawValue) seconds"
    }
}

struct LocalRefreshSettingsStore {
    static let storageKey = "LimitBar.localRefreshSettingsJSON"

    private struct Envelope: Codable {
        let version: Int
        let cadenceSeconds: Int
    }

    private static let currentVersion = 1
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var cadence: LocalRefreshCadence {
        get {
            guard let data = defaults.data(forKey: Self.storageKey),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.version == Self.currentVersion,
                  let cadence = LocalRefreshCadence(rawValue: envelope.cadenceSeconds) else {
                return .fiveSeconds
            }
            return cadence
        }
        nonmutating set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let envelope = Envelope(version: Self.currentVersion, cadenceSeconds: newValue.rawValue)
            guard let data = try? encoder.encode(envelope) else { return }
            defaults.set(data, forKey: Self.storageKey)
            notificationCenter.post(name: .localRefreshSettingsDidChange, object: nil)
        }
    }
}
