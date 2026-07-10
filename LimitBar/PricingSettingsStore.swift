import Foundation
import LimitBarCore

struct PricingSettingsStore {
    static let storageKey = "LimitBar.pricingEntriesJSON"
    static let defaultJSON = "[]"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var entries: [PricingEntry] {
        get { Self.entries(from: defaults.string(forKey: Self.storageKey) ?? Self.defaultJSON) }
        nonmutating set { defaults.set(Self.json(from: newValue), forKey: Self.storageKey) }
    }

    var pricingTable: PricingTable {
        PricingTable(entries: entries)
    }

    func add(_ entry: PricingEntry) {
        entries = entries.filter { existing in
            !(existing.provider == entry.provider
              && existing.modelLabel == entry.modelLabel
              && existing.effectiveAt == entry.effectiveAt)
        } + [entry]
    }

    static func table(from json: String) -> PricingTable {
        PricingTable(entries: entries(from: json))
    }

    private static func entries(from json: String) -> [PricingEntry] {
        guard let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([PricingEntry].self, from: data)) ?? []
    }

    private static func json(from entries: [PricingEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries), let json = String(data: data, encoding: .utf8) else {
            return Self.defaultJSON
        }
        return json
    }
}
