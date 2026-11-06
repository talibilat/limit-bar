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

    /// Codex keeps its data in `$CODEX_HOME` when that variable is set, otherwise in `~/.codex`.
    /// Pass the process environment from the app; tests use the empty default so results stay fixed.
    public static func codexSessionsDirectory(homeDirectory: URL, environment: [String: String] = [:]) -> URL {
        if let custom = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let expanded = custom == "~" || custom.hasPrefix("~/")
                ? homeDirectory.path + custom.dropFirst()
                : custom
            return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Claude Code keeps transcripts in `$CLAUDE_CONFIG_DIR/projects` when that variable is set, otherwise `~/.claude/projects`.
    public static func claudeProjectsDirectory(homeDirectory: URL, environment: [String: String] = [:]) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let expanded = custom == "~" || custom.hasPrefix("~/")
                ? homeDirectory.path + custom.dropFirst()
                : custom
            return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public var claudeCodeUsageEventsFile: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("claude-code-usage-events.jsonl")
    }

    public var codexUsageEventsFile: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("codex-usage-events.jsonl")
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

    public var organizationDirectory: URL {
        limitBarApplicationSupportDirectory.appendingPathComponent("Organization", isDirectory: true)
    }

    public var organizationCapacityDatabase: URL {
        organizationDirectory.appendingPathComponent("team-capacity-v1.sqlite")
    }

    public var organizationAliasKey: URL {
        organizationDirectory.appendingPathComponent("team-alias-v1.key")
    }

    public var organizationDeletionMarker: URL {
        organizationDirectory.appendingPathComponent("deletion-v1.pending")
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
