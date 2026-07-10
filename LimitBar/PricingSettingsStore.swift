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

    @discardableResult
    func add(_ entry: PricingEntry) -> Bool {
        guard !entry.modelLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.inputPricePerMillionTokens >= 0,
              entry.outputPricePerMillionTokens >= 0 else {
            return false
        }

        entries = entries.filter { existing in
            !(existing.provider == entry.provider
              && existing.modelLabel == entry.modelLabel
              && existing.effectiveAt == entry.effectiveAt)
        } + [entry]

        return true
    }

    static func table(from json: String) -> PricingTable {
        PricingTable(entries: entries(from: json))
    }

    static func strictDecimal(from text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
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
