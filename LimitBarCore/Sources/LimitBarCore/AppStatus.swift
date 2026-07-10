public struct AppStatus: Equatable, Sendable {
    public let menuBarText: String
    public let symbolName: String
    public let statusColor: MenuBarStatusColor
    public let accessibilityDescription: String

    public var statusColorName: String { statusColor.rawValue }

    public init(
        menuBarText: String,
        symbolName: String,
        statusColor: MenuBarStatusColor = .gray,
        accessibilityDescription: String
    ) {
        self.menuBarText = menuBarText
        self.symbolName = symbolName
        self.statusColor = statusColor
        self.accessibilityDescription = accessibilityDescription
    }

    public static let initial = AppStatus(
        menuBarText: "LimitBar",
        symbolName: "gauge.with.dots.needle.bottom.50percent",
        statusColor: .gray,
        accessibilityDescription: "LimitBar usage monitor"
    )

    public static func from(menuBarStatus: MenuBarStatus) -> AppStatus {
        let text = menuBarStatus.confirmedUsagePercentage.map { "\($0)%" } ?? "LimitBar"
        let accessibilityDescription = "LimitBar usage monitor, \(text), \(menuBarStatus.color.rawValue)"

        return AppStatus(
            menuBarText: text,
            symbolName: "gauge.with.dots.needle.bottom.50percent",
            statusColor: menuBarStatus.color,
            accessibilityDescription: accessibilityDescription
        )
    }
}
