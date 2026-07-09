public struct AppStatus: Equatable, Sendable {
    public let menuBarText: String
    public let symbolName: String
    public let accessibilityDescription: String

    public init(
        menuBarText: String,
        symbolName: String,
        accessibilityDescription: String
    ) {
        self.menuBarText = menuBarText
        self.symbolName = symbolName
        self.accessibilityDescription = accessibilityDescription
    }

    public static let initial = AppStatus(
        menuBarText: "LimitBar",
        symbolName: "gauge.with.dots.needle.bottom.50percent",
        accessibilityDescription: "LimitBar usage monitor"
    )
}
