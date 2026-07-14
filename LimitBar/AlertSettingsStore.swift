import Foundation
import LimitBarCore

extension Notification.Name {
    static let alertSettingsDidChange = Notification.Name("LimitBar.alertSettingsDidChange")
}

struct AlertSettingsStore {
    static let storageKey = "LimitBar.alertPreferencesJSON"

    private struct Envelope: Codable {
        let version: Int
        let preferences: AlertPreferences
    }

    private static let currentVersion = 1
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var preferences: AlertPreferences {
        guard let data = defaults.data(forKey: Self.storageKey) else { return Self.defaultPreferences }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion else {
            return Self.closedPreferences
        }
        return envelope.preferences
    }

    @discardableResult
    func replaceRules(with preferences: AlertPreferences) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Envelope(version: Self.currentVersion, preferences: preferences)) else {
            return false
        }
        defaults.set(data, forKey: Self.storageKey)
        notificationCenter.post(name: .alertSettingsDidChange, object: nil)
        return true
    }

    @discardableResult
    func replaceQuotaRules(_ rules: [QuotaAlertRule]) -> Bool {
        guard let updated = try? AlertPreferences(quotaRules: rules, costBudgetRules: preferences.costBudgetRules) else {
            return false
        }
        return replaceRules(with: updated)
    }

    @discardableResult
    func replaceCostBudgetRules(_ rules: [CostBudgetAlertRule]) -> Bool {
        guard let updated = try? AlertPreferences(quotaRules: preferences.quotaRules, costBudgetRules: rules) else {
            return false
        }
        return replaceRules(with: updated)
    }

    func reset() {
        _ = replaceRules(with: Self.defaultPreferences)
    }

    private static let defaultPreferences = try! AlertPreferences(
        quotaRules: [
            QuotaAlertRule(product: .claudeCode, isEnabled: false),
            QuotaAlertRule(product: .codex, isEnabled: false)
        ],
        costBudgetRules: []
    )

    private static let closedPreferences = try! AlertPreferences(quotaRules: [], costBudgetRules: [])
}
