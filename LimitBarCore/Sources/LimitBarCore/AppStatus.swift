public struct AppStatus: Equatable, Sendable {
    public let menuBarText: String
    public let symbolName: String
    public let statusColorName: String
    public let accessibilityDescription: String

    public init(
        menuBarText: String,
        symbolName: String,
        statusColorName: String = "gray",
        accessibilityDescription: String
    ) {
        self.menuBarText = menuBarText
        self.symbolName = symbolName
        self.statusColorName = statusColorName
        self.accessibilityDescription = accessibilityDescription
    }

    public static let initial = AppStatus(
        menuBarText: "LimitBar",
        symbolName: "gauge.with.dots.needle.bottom.50percent",
        statusColorName: "gray",
        accessibilityDescription: "LimitBar usage monitor"
    )

    public static func from(menuBarStatus: MenuBarStatus) -> AppStatus {
        let text = menuBarStatus.confirmedUsagePercentage.map { "\($0)%" } ?? "LimitBar"
        let colorName = menuBarStatus.color.rawValue
        let accessibilityDescription = "LimitBar usage monitor, \(text), \(colorName)"

        return AppStatus(
            menuBarText: text,
            symbolName: "gauge.with.dots.needle.bottom.50percent",
            statusColorName: colorName,
            accessibilityDescription: accessibilityDescription
        )
    }
}
