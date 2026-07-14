import Foundation
import LimitBarCore
import Observation
import UserNotifications

enum AlertAuthorizationStatus: String {
    case notDetermined = "Not enabled"
    case denied = "Denied in System Settings"
    case authorized = "Enabled"
    case provisional = "Provisionally enabled"
    case unknown = "Unavailable"
}

@MainActor
protocol AlertNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(identifier: String, title: String, body: String) async throws
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

@MainActor
final class UserNotificationsAdapter: NSObject, AlertNotificationCenter, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(identifier: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }

    func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
@Observable
final class AlertCoordinator {
    private static let notificationPrefix = "limitbar.alert."

    private(set) var authorizationStatus: AlertAuthorizationStatus = .unknown
    private(set) var lastErrorMessage: String?

    private let settingsStore: AlertSettingsStore
    private let notificationCenter: any AlertNotificationCenter
    private let deliveryStore: SQLiteAlertDeliveryStore?
    private var activeEvaluations = 0
    private var isClearingHistory = false

    convenience init(settingsStore: AlertSettingsStore) {
        self.init(
            settingsStore: settingsStore,
            notificationCenter: UserNotificationsAdapter(),
            deliveryStore: try? .applicationSupportStore()
        )
    }

    init(
        settingsStore: AlertSettingsStore,
        notificationCenter: any AlertNotificationCenter,
        deliveryStore: SQLiteAlertDeliveryStore?
    ) {
        self.settingsStore = settingsStore
        self.notificationCenter = notificationCenter
        self.deliveryStore = deliveryStore
        if deliveryStore == nil {
            lastErrorMessage = "Notification delivery history is unavailable. Alerts are suppressed."
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = Self.simpleStatus(await notificationCenter.authorizationStatus())
    }

    func enableNotifications() async {
        do {
            _ = try await notificationCenter.requestAuthorization()
            lastErrorMessage = deliveryStore == nil ? "Notification delivery history is unavailable. Alerts are suppressed." : nil
        } catch {
            lastErrorMessage = "Notification permission could not be requested."
        }
        await refreshAuthorizationStatus()
    }

    func evaluate(quota: [QuotaObservation], costs: [CostBudgetObservation], now: Date = Date()) async {
        guard let deliveryStore, !isClearingHistory else { return }
        activeEvaluations += 1
        defer { activeEvaluations -= 1 }
        let systemStatus = await notificationCenter.authorizationStatus()
        authorizationStatus = Self.simpleStatus(systemStatus)
        guard systemStatus == .authorized || systemStatus == .provisional else { return }

        do {
            try deliveryStore.prune(through: now)
            let preferences = settingsStore.preferences
            let candidates = AlertEvaluator.evaluate(
                preferences: preferences,
                quota: quota,
                costs: costs,
                satisfied: [],
                now: now
            )
            var satisfied = Set<AlertThresholdSatisfaction>()
            for candidate in candidates {
                let occurrence = candidate.occurrence
                satisfied.formUnion(try deliveryStore.satisfactions(for: occurrence.ruleID, window: occurrence.window))
            }
            let evaluations = AlertEvaluator.evaluate(
                preferences: preferences,
                quota: quota,
                costs: costs,
                satisfied: satisfied,
                now: now
            )
            for evaluation in evaluations {
                do {
                    guard let reservation = try deliveryStore.reserve(evaluation.occurrence, now: now) else { continue }
                    let identifier = Self.identifier(for: reservation)
                    let pending = await notificationCenter.pendingIdentifiers()
                    let delivered = await notificationCenter.deliveredIdentifiers()
                    let accepted = Set(pending + delivered)
                    if !accepted.contains(identifier) {
                        do {
                            try await notificationCenter.add(
                                identifier: identifier,
                                title: evaluation.notification.title,
                                body: evaluation.notification.body
                            )
                        } catch {
                            try? deliveryStore.markFailed(reservation)
                            lastErrorMessage = "A notification could not be delivered and will be retried."
                            continue
                        }
                    }
                    do {
                        try deliveryStore.markDelivered(reservation, at: Date())
                    } catch {
                        try? deliveryStore.retainAcceptedReservation(reservation)
                        lastErrorMessage = "An accepted notification could not be recorded yet."
                    }
                } catch {
                    lastErrorMessage = "Notification delivery history could not be updated."
                }
            }
        } catch {
            lastErrorMessage = "Notification delivery history could not be maintained."
        }
    }

    func clearHistory() async {
        guard !isClearingHistory else { return }
        isClearingHistory = true
        defer { isClearingHistory = false }
        while activeEvaluations > 0 {
            await Task.yield()
        }
        do {
            try deliveryStore?.reset()
            let pending = await notificationCenter.pendingIdentifiers().filter { $0.hasPrefix(Self.notificationPrefix) }
            let delivered = await notificationCenter.deliveredIdentifiers().filter { $0.hasPrefix(Self.notificationPrefix) }
            notificationCenter.removePending(identifiers: pending)
            notificationCenter.removeDelivered(identifiers: delivered)
            lastErrorMessage = deliveryStore == nil ? "Notification delivery history is unavailable. Alerts are suppressed." : nil
        } catch {
            lastErrorMessage = "Notification history could not be cleared."
        }
    }

    private static func simpleStatus(_ status: UNAuthorizationStatus) -> AlertAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional, .ephemeral: .provisional
        @unknown default: .unknown
        }
    }

    private static func identifier(for reservation: AlertDeliveryReservation) -> String {
        let occurrence = reservation.occurrence
        let threshold = occurrence.thresholds.max() ?? 0
        let window = Data(occurrence.window.canonicalIdentifier.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return "\(notificationPrefix)\(occurrence.ruleID.uuidString).\(window).\(threshold)"
    }
}
