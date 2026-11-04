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
    @State private var savedMessage: String?
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
        SettingsPage(
            title: "Alerts",
            subtitle: "Get notified as you near a limit or a budget. Alerts use data already on this Mac and never show account, model or spend values.",
            trailing: {
                Button("Save Changes") { save() }
                    .buttonStyle(SettingsButtonStyle(.primary))
                    .accessibilityIdentifier("alerts-save")
            }
        ) {
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            if let savedMessage {
                Text(savedMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if !notificationsEnabled {
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(SettingsTone.warning.foreground)
                    SettingsRowText(title: "macOS notifications are off", detail: "Status: \(coordinator.authorizationStatus.rawValue)")
                    Button("Enable Notifications") {
                        Task { await coordinator.enableNotifications() }
                    }
                    .buttonStyle(SettingsButtonStyle(.normal))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SettingsPalette.border))
            }

            if let lastErrorMessage = coordinator.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTone.warning.foreground)
            }

            SettingsGroup("Quota alerts", caption: "Alert when a plan limit reaches these percentages") {
                ForEach(Array($quotaDrafts.enumerated()), id: \.element.id) { offset, $draft in
                    if offset > 0 { Divider() }
                    SettingsRow {
                        Toggle("\(draft.product.displayName) quota alerts", isOn: $draft.isEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                        SettingsRowText(
                            title: draft.product.displayName,
                            detail: draft.product == .claudeCode ? "Subscription quota" : "Codex plan quota"
                        )
                        Text("At")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("70, 90", text: $draft.thresholds)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .accessibilityLabel("\(draft.product.displayName) thresholds")
                        Text("%")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsGroup("Cost budgets", caption: "API accounts only") {
                ForEach($budgetDrafts) { $draft in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Toggle("Budget enabled", isOn: $draft.isEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                            Text(budgetTitle(draft))
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Remove") { removeBudget(id: draft.id) }
                                .buttonStyle(SettingsButtonStyle(.danger))
                        }
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                SettingsField("Account") {
                                    Picker("Account", selection: $draft.product) {
                                        Text("Anthropic API").tag(ProviderProduct.anthropicAPI)
                                        Text("OpenAI API").tag(ProviderProduct.openAIAPI)
                                        Text("Azure OpenAI").tag(ProviderProduct.azureOpenAI)
                                    }
                                    .labelsHidden()
                                }
                                SettingsField("Cost source") {
                                    Picker("Cost source", selection: $draft.source) {
                                        Text("Provider reported").tag(CostSource.providerReported.rawValue)
                                        Text("Calculated estimate").tag(CostSource.calculatedEstimate.rawValue)
                                    }
                                    .labelsHidden()
                                }
                                SettingsField("Period") {
                                    Picker("Period", selection: $draft.period) {
                                        ForEach(BudgetPeriod.options(for: CostSource(rawValue: draft.source) ?? .providerReported), id: \.self) { period in
                                            Text(period.label).tag(period)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                            GridRow {
                                SettingsField("Currency") {
                                    TextField("USD", text: $draft.currencyCode)
                                        .labelsHidden()
                                }
                                SettingsField("Cap") {
                                    TextField("10", text: $draft.cap)
                                        .labelsHidden()
                                }
                                SettingsField("Alert at (%)") {
                                    TextField("70, 90", text: $draft.thresholds)
                                        .labelsHidden()
                                }
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draft.source) { _, source in
                            draft.period = source == CostSource.providerReported.rawValue ? .weekUTC : .todayLocal
                        }
                    }
                    .padding(16)
                    Divider()
                }

                HStack(spacing: 12) {
                    Button {
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
                    } label: {
                        Label("Add Budget", systemImage: "plus")
                    }
                    .buttonStyle(SettingsButtonStyle(.normal))
                    Text("Provider reported uses spend from the API. Calculated estimate uses your prices in Sources & Pricing.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            SettingsGroup("Reset") {
                resetRow(title: "Reset alert rules", detail: "Turns off all quota alerts and removes budgets", button: "Reset Rules…") {
                    showResetConfirmation = true
                }
                Divider()
                resetRow(title: "Clear notification history", detail: "Active thresholds may alert again on the next reading", button: "Clear History…") {
                    showClearConfirmation = true
                }
                Divider()
                resetRow(title: "Reset everything", detail: "Rules, delivery history and delivered notifications", button: "Reset All…") {
                    showCompleteResetConfirmation = true
                }
            }
        }
        .task { await coordinator.refreshAuthorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .alertSettingsDidChange)) { _ in
            reload()
        }
        .confirmationDialog("Reset all alert settings?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Alert Settings", role: .destructive) {
                store.reset()
                validationMessage = nil
                savedMessage = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quota alerts are turned off and every cost budget is removed.")
        }
        .confirmationDialog("Clear notification history?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                Task { await coordinator.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delivered and pending LimitBar notifications will be removed. Active thresholds may alert again on the next snapshot.")
        }
        .confirmationDialog("Reset all alert data?", isPresented: $showCompleteResetConfirmation, titleVisibility: .visible) {
            Button("Reset Settings and History", role: .destructive) {
                store.reset()
                Task { await coordinator.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Configured rules, delivery history, and pending or delivered LimitBar notifications will be removed.")
        }
    }

    private var notificationsEnabled: Bool {
        coordinator.authorizationStatus == .authorized || coordinator.authorizationStatus == .provisional
    }

    private func budgetTitle(_ draft: BudgetDraft) -> String {
        let cap = draft.cap.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = draft.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let period = draft.period == .todayLocal ? "per day" : "per week"
        return "\(draft.product.displayName) · \(cap.isEmpty ? "–" : cap) \(currency) \(period)"
    }

    private func resetRow(title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        SettingsRow(verticalPadding: 12) {
            SettingsRowText(title: title, detail: detail, emphasized: false)
            Button(button, action: action)
                .buttonStyle(SettingsButtonStyle(.danger))
        }
    }

    private func save() {
        savedMessage = nil
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
            let saved = store.replaceRules(with: preferences)
            validationMessage = saved ? nil : "Alert settings could not be saved."
            savedMessage = saved ? "Alert settings saved." : nil
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
