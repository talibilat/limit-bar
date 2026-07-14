import Foundation
import LimitBarCore

extension Notification.Name {
    static let customUsageSourcesDidChange = Notification.Name("limitbar.customUsageSourcesDidChange")
}

struct CustomUsageSourceStore {
    static let storageKey = "LimitBar.customUsageSourcesJSON"
    static let defaultJSON = "[]"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? Self.defaultDefaults
    }

    private static var defaultDefaults: UserDefaults {
#if DEBUG
        AppUITestConfiguration.userDefaults ?? .standard
#else
        .standard
#endif
    }

    var sources: [CustomUsageSource] {
        get { Self.sources(from: defaults.string(forKey: Self.storageKey) ?? Self.defaultJSON) }
        nonmutating set {
            defaults.set(Self.json(from: newValue), forKey: Self.storageKey)
            NotificationCenter.default.post(name: .customUsageSourcesDidChange, object: nil)
        }
    }

    @discardableResult
    func add(name: String, filePath: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPath.isEmpty else {
            return false
        }
        sources = sources + [CustomUsageSource(name: trimmedName, filePath: trimmedPath)]
        return true
    }

    func remove(id: UUID) {
        sources = sources.filter { $0.id != id }
    }

    static func sources(from json: String) -> [CustomUsageSource] {
        guard let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([CustomUsageSource].self, from: data)) ?? []
    }

    private static func json(from sources: [CustomUsageSource]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sources), let json = String(data: data, encoding: .utf8) else {
            return defaultJSON
        }
        return json
    }
}
