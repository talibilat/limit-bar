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
        get {
            let json = defaults.string(forKey: Self.storageKey) ?? Self.defaultJSON
            return (try? JSONDecoder().decode([CustomUsageSource].self, from: Data(json.utf8))) ?? []
        }
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
        let fileURL = URL(fileURLWithPath: trimmedPath)
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return false
        }
        sources = sources + [CustomUsageSource(name: trimmedName, filePath: trimmedPath)]
        return true
    }

    func remove(id: UUID) {
        sources = sources.filter { $0.id != id }
    }

    private static func json(from sources: [CustomUsageSource]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sources) else {
            return defaultJSON
        }
        return String(decoding: data, as: UTF8.self)
    }
}
