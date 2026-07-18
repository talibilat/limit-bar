import Foundation

public struct LimitBarFileLocations: Equatable, Sendable {
    public let homeDirectory: URL
    public let applicationSupportDirectory: URL

    public init(homeDirectory: URL, applicationSupportDirectory: URL) {
        self.homeDirectory = homeDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var codexSessionsDirectory: URL {
        Self.codexSessionsDirectory(homeDirectory: homeDirectory)
    }

    public static func codexSessionsDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public var limitBarApplicationSupportDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("LimitBar", isDirectory: true)
    }

    public var usageEventsFile: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("usage-events.jsonl")
    }

    public var usageMetricsDatabase: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("usage-metrics.sqlite")
    }

    public var historicalUsageDatabase: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("historical-usage-trends.sqlite")
    }

    public var capacityPublication: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("capacity-v1.json")
    }

    public var recoveryInbox: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("recovery-inbox-v1.json")
    }

    public var recoveryFingerprintKey: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("recovery-fingerprint-v1.key")
    }

    public var activityReceiptsDatabase: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("activity-receipts-v1.sqlite")
    }

    public var apiSpendReconciliationDatabase: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("api-spend-reconciliation-v2.sqlite")
    }

    public static func production(fileManager: FileManager = .default) throws -> Self {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let locations = Self(
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            applicationSupportDirectory: applicationSupport
        )
        try fileManager.createDirectory(at: locations.limitBarApplicationSupportDirectory, withIntermediateDirectories: true)
        return locations
    }
}
