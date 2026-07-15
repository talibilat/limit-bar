import SwiftUI
import LimitBarCore

struct AlertSettingsView: View {
    private struct QuotaDraft: Identifiable {
        let id: UUID
        let product: ProviderProduct
        var isEnabled: Bool
        var thresholds: String
    }

    private struct BudgetDraft: Identifiable {
        let id: UUID
        var product: ProviderProduct
        var source: String
        var period: BudgetPeriod
        var currencyCode: String
        var cap: String
        var thresholds: String
        var isEnabled: Bool
    }

    private enum BudgetPeriod: String, CaseIterable, Hashable {
        case todayLocal
        case weekLocal
        case weekUTC

        var label: String {
            switch self {
            case .todayLocal: "Today / local"
            case .weekLocal: "Current Week / local"
            case .weekUTC: "Current Week / UTC"
            }
        }

        var timeWindow: TimeWindow { self == .todayLocal ? .today : .currentWeek }
        var basis: UsageWindowBasis { self == .weekUTC ? .utcBilling : .localCalendar }

        static func options(for source: CostSource) -> [BudgetPeriod] {
            source == .providerReported ? [.weekUTC] : [.todayLocal, .weekLocal]
        }

        init(timeWindow: TimeWindow, basis: UsageWindowBasis) {
            if timeWindow == .today {
                self = .todayLocal
            } else if basis == .utcBilling {
                self = .weekUTC
            } else {
                self = .weekLocal
            }
        }
    }

    let store: AlertSettingsStore
    let coordinator: AlertCoordinator

    @State private var quotaDrafts: [QuotaDraft]
    @State private var budgetDrafts: [BudgetDraft]
    @State private var validationMessage: String?
    @State private var showResetConfirmation = false
    @State private var showClearConfirmation = false
    @State private var showCompleteResetConfirmation = false

    init(store: AlertSettingsStore, coordinator: AlertCoordinator) {
        self.store = store
        self.coordinator = coordinator
        let preferences = store.preferences
        _quotaDrafts = State(initialValue: Self.makeQuotaDrafts(from: preferences))
        _budgetDrafts = State(initialValue: preferences.costBudgetRules.map(Self.makeBudgetDraft))
    }

    var body: some View {
        Section("Alerts") {
            Text("LimitBar evaluates snapshots already collected on this Mac. Alerts do not add provider polling, read extra Keychain data, or include account, project, deployment, model, token, or spend values in notification text.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Notifications", value: coordinator.authorizationStatus.rawValue)
            Button("Enable Notifications") {
                Task { await coordinator.enableNotifications() }
            }
            .disabled(coordinator.authorizationStatus == .authorized || coordinator.authorizationStatus == .provisional)

            if let lastErrorMessage = coordinator.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            DisclosureGroup("Quota alerts") {
                Text("Claude Code rules use Claude Code subscription quota snapshots. Codex rules use local Codex session quota snapshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(APIProviderQuotaPathAvailability.fixedUnavailableSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach($quotaDrafts) { $draft in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(draft.product.displayName, isOn: $draft.isEnabled)
                        TextField("Thresholds, for example 70, 90", text: $draft.thresholds)
                    }
                    .padding(.vertical, 4)
                }
            }

            DisclosureGroup("Cost budgets") {
                Text("Provider reported uses spend returned by the selected provider API. Calculated estimate uses token usage and your Pricing settings. Custom usage sources are not eligible for budget alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach($budgetDrafts) { $draft in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Enabled", isOn: $draft.isEnabled)
                            Spacer()
                            Button("Remove") { removeBudget(id: draft.id) }
                        }
                        Picker("Provider product", selection: $draft.product) {
                            Text("Anthropic API").tag(ProviderProduct.anthropicAPI)
                            Text("OpenAI API").tag(ProviderProduct.openAIAPI)
                            Text("Azure OpenAI").tag(ProviderProduct.azureOpenAI)
                        }
                        Picker("Cost source", selection: $draft.source) {
                            Text("Provider reported").tag(CostSource.providerReported.rawValue)
                            Text("Calculated estimate").tag(CostSource.calculatedEstimate.rawValue)
                        }
                        Picker("Billing period", selection: $draft.period) {
                            ForEach(BudgetPeriod.options(for: CostSource(rawValue: draft.source) ?? .providerReported), id: \.self) { period in
                                Text(period.label).tag(period)
                            }
                        }
                        .onChange(of: draft.source) { _, source in
                            draft.period = source == CostSource.providerReported.rawValue ? .weekUTC : .todayLocal
                        }
                        HStack {
                            TextField("Currency (USD)", text: $draft.currencyCode)
                            TextField("Positive cap", text: $draft.cap)
                        }
                        TextField("Thresholds, for example 70, 90", text: $draft.thresholds)
                    }
                    .padding(.vertical, 8)
                }

                Button("Add Cost Budget") {
                    budgetDrafts.append(BudgetDraft(
                        id: UUID(),
                        product: .anthropicAPI,
                        source: CostSource.providerReported.rawValue,
                        period: .weekUTC,
                        currencyCode: "USD",
                        cap: "10",
                        thresholds: "70, 90",
                        isEnabled: true
                    ))
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Save Alert Settings") { save() }
                Button("Reset Settings", role: .destructive) { showResetConfirmation = true }
                Button("Clear Notification History", role: .destructive) { showClearConfirmation = true }
                Button("Reset All Alert Data", role: .destructive) { showCompleteResetConfirmation = true }
            }
        }
        .task { await coordinator.refreshAuthorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .alertSettingsDidChange)) { _ in
            reload()
        }
        .confirmationDialog("Reset all alert settings?", isPresented: $showResetConfirmation) {
            Button("Reset Alert Settings", role: .destructive) {
                store.reset()
                validationMessage = nil
            }
        }
        .confirmationDialog("Clear notification history?", isPresented: $showClearConfirmation) {
            Button("Clear History", role: .destructive) {
                Task { await coordinator.clearHistory() }
            }
        } message: {
            Text("Delivered and pending LimitBar notifications will be removed. Active thresholds may alert again on the next snapshot.")
        }
        .confirmationDialog("Reset all alert data?", isPresented: $showCompleteResetConfirmation) {
            Button("Reset Settings and History", role: .destructive) {
                store.reset()
                Task { await coordinator.clearHistory() }
            }
        } message: {
            Text("Configured rules, delivery history, and pending or delivered LimitBar notifications will be removed.")
        }
    }

    private func save() {
        do {
            let quotaRules = try quotaDrafts.map { draft in
                QuotaAlertRule(
                    id: draft.id,
                    product: draft.product,
                    thresholds: try thresholds(from: draft.thresholds),
                    isEnabled: draft.isEnabled
                )
            }
            let costRules = try budgetDrafts.map { draft in
                guard let source = CostSource(rawValue: draft.source),
                      let cap = PricingSettingsStore.strictDecimal(from: draft.cap), cap > 0 else {
                    throw AlertValidationError.invalidBudgetCap
                }
                return try CostBudgetAlertRule(
                    id: draft.id,
                    product: draft.product,
                    currencyCode: draft.currencyCode,
                    source: source,
                    timeWindow: draft.period.timeWindow,
                    basis: draft.period.basis,
                    cap: cap,
                    thresholds: try thresholds(from: draft.thresholds),
                    isEnabled: draft.isEnabled
                )
            }
            let preferences = try AlertPreferences(quotaRules: quotaRules, costBudgetRules: costRules)
            validationMessage = store.replaceRules(with: preferences) ? nil : "Alert settings could not be saved."
        } catch AlertValidationError.invalidThreshold {
            validationMessage = "Thresholds must be unique whole numbers from 1 through 100."
        } catch AlertValidationError.invalidCurrencyCode {
            validationMessage = "Currency must be a three-letter code such as USD."
        } catch AlertValidationError.invalidBudgetCap {
            validationMessage = "Each cost budget needs a positive cap."
        } catch {
            validationMessage = "Review the alert rules and try again."
        }
    }

    private func thresholds(from text: String) throws -> PercentageThresholds {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty }),
              parts.allSatisfy({ Int($0) != nil }) else {
            throw AlertValidationError.invalidThreshold
        }
        let values = parts.compactMap(Int.init)
        guard Set(values).count == values.count else { throw AlertValidationError.invalidThreshold }
        return try PercentageThresholds(values)
    }

    private func removeBudget(id: UUID) {
        budgetDrafts.removeAll { $0.id == id }
    }

    private func reload() {
        let preferences = store.preferences
        quotaDrafts = Self.makeQuotaDrafts(from: preferences)
        budgetDrafts = preferences.costBudgetRules.map(Self.makeBudgetDraft)
    }

    private static func makeQuotaDrafts(from preferences: AlertPreferences) -> [QuotaDraft] {
        [ProviderProduct.claudeCode, ProviderProduct.codex].map { product in
            if let rule = preferences.quotaRules.first(where: { $0.product == product }) {
                return QuotaDraft(
                    id: rule.id,
                    product: product,
                    isEnabled: rule.isEnabled,
                    thresholds: rule.thresholds.values.map(String.init).joined(separator: ", ")
                )
            }
            return QuotaDraft(id: UUID(), product: product, isEnabled: false, thresholds: "70, 90")
        }
    }

    private static func makeBudgetDraft(_ rule: CostBudgetAlertRule) -> BudgetDraft {
        BudgetDraft(
            id: rule.id,
            product: rule.product,
            source: rule.source.rawValue,
            period: BudgetPeriod(timeWindow: rule.timeWindow, basis: rule.basis),
            currencyCode: rule.currencyCode,
            cap: rule.cap.description,
            thresholds: rule.thresholds.values.map(String.init).joined(separator: ", "),
            isEnabled: rule.isEnabled
        )
    }
}
