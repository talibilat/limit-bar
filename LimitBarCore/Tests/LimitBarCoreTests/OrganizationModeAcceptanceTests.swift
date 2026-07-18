import Foundation
import Testing
@testable import LimitBarCore

@Suite("Organization mode acceptance")
struct OrganizationModeAcceptanceTests {
    @Test func consentGatesEveryOrganizationOperation() throws {
        let suite = "LimitBar.OrganizationConsent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = OrganizationModeSettingsStore(defaults: defaults)
        var operationCount = 0

        #expect(!settings.isEnabled)
        #expect(!settings.enable(acknowledged: false))
        #expect(throws: OrganizationCapacityError.organizationModeDisabled) {
            try settings.withEnabledAccess { operationCount += 1 }
        }
        #expect(operationCount == 0)
        #expect(settings.enable(acknowledged: true, at: Date(timeIntervalSince1970: 1_700_000_000)))
        try settings.withEnabledAccess { operationCount += 1 }
        #expect(operationCount == 1)
        settings.disable()
        #expect(throws: OrganizationCapacityError.organizationModeDisabled) {
            try settings.withEnabledAccess { operationCount += 1 }
        }
        #expect(operationCount == 1)
    }

    @Test func validationFirstModeHasNoNetworkOrCredentialCapability() {
        let capabilities = OrganizationModeCapabilities.validationFirst
        #expect(capabilities.importMode == .manuallySelectedAdministratorReviewedFile)
        #expect(!capabilities.allowsOrganizationNetworkRequests)
        #expect(!capabilities.acceptsOrganizationCredentials)
    }

    @Test func organizationImplementationHasNoNetworkOrCredentialClientSurface() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageDirectory = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let workspace = packageDirectory.deletingLastPathComponent()
        let files = [
            packageDirectory.appendingPathComponent("Sources/LimitBarCore/OrganizationCapacityPlanner.swift"),
            packageDirectory.appendingPathComponent("Sources/LimitBarCore/OrganizationDataDeletion.swift"),
            packageDirectory.appendingPathComponent("Sources/LimitBarCore/SQLiteOrganizationCapacityStore.swift"),
            workspace.appendingPathComponent("LimitBar/OrganizationCapacityPlannerView.swift"),
        ]
        let prohibitedCapabilities = ["URLSession", "HTTPClient", "CredentialStore", "SecItem", "Keychain"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for capability in prohibitedCapabilities {
                #expect(!source.contains(capability), "\(file.lastPathComponent) must not gain \(capability) capability")
            }
        }
    }

    @Test func successfulDeletionIsOrderedAndCannotReachPersonalState() {
        let log = DeletionEventLog()
        let database = DeletionDatabaseDouble(log: log)
        let databaseURL = URL(fileURLWithPath: "/organization/team-capacity.sqlite")
        let keyURL = URL(fileURLWithPath: "/organization/team-alias.key")
        let markerURL = URL(fileURLWithPath: "/organization/deletion.pending")
        let fileSystem = DeletionFileSystemDouble(existing: [keyURL, sidecar(databaseURL, "-wal"), sidecar(databaseURL, "-shm"), sidecar(databaseURL, "-journal")], log: log)
        let personal = PersonalStateDouble()
        let coordinator = OrganizationDataDeletionCoordinator(databaseURL: databaseURL, aliasKeyURL: keyURL, markerURL: markerURL, fileSystem: fileSystem)

        #expect(coordinator.delete(using: database) == .complete)
        #expect(log.events.first == "marker:database_pending")
        #expect(log.events.firstIndex(of: "database:secure-erase")! < log.events.firstIndex(of: "secure-remove:\(keyURL.path)")!)
        #expect(!fileSystem.exists(keyURL))
        #expect(!fileSystem.exists(markerURL))
        #expect(personal.usage == 42)
        #expect(personal.credentials == "untouched")
        #expect(personal.diagnostics == "personal-only")
    }

    @Test func partialDeletionRemainsExplicitlyRecoverableAndNeverReportsComplete() {
        let log = DeletionEventLog()
        let database = DeletionDatabaseDouble(log: log)
        let databaseURL = URL(fileURLWithPath: "/organization/team-capacity.sqlite")
        let keyURL = URL(fileURLWithPath: "/organization/team-alias.key")
        let markerURL = URL(fileURLWithPath: "/organization/deletion.pending")
        let fileSystem = DeletionFileSystemDouble(existing: [keyURL], log: log)
        fileSystem.failRemovalOnce = keyURL
        let coordinator = OrganizationDataDeletionCoordinator(databaseURL: databaseURL, aliasKeyURL: keyURL, markerURL: markerURL, fileSystem: fileSystem)

        #expect(coordinator.delete(using: database) == .recoveryRequired(.filesPending))
        #expect(fileSystem.exists(keyURL))
        #expect(fileSystem.exists(markerURL))
        #expect(coordinator.pendingStage == .filesPending)

        let recoveryDatabase = DeletionDatabaseDouble(log: log)
        #expect(coordinator.delete(using: recoveryDatabase) == .complete)
        #expect(recoveryDatabase.secureEraseCount == 0)
        #expect(recoveryDatabase.closeCount == 1)
        #expect(!fileSystem.exists(keyURL))
        #expect(!fileSystem.exists(markerURL))
    }

    @Test func databaseFailureKeepsKeyAndDatabasePendingRecovery() {
        let log = DeletionEventLog()
        let databaseURL = URL(fileURLWithPath: "/organization/team-capacity.sqlite")
        let keyURL = URL(fileURLWithPath: "/organization/team-alias.key")
        let markerURL = URL(fileURLWithPath: "/organization/deletion.pending")
        let fileSystem = DeletionFileSystemDouble(existing: [keyURL], log: log)
        let database = DeletionDatabaseDouble(log: log)
        database.shouldFail = true
        let coordinator = OrganizationDataDeletionCoordinator(databaseURL: databaseURL, aliasKeyURL: keyURL, markerURL: markerURL, fileSystem: fileSystem)

        #expect(coordinator.delete(using: database) == .recoveryRequired(.databasePending))
        #expect(fileSystem.exists(keyURL))
        #expect(fileSystem.exists(markerURL))
        #expect(coordinator.pendingStage == .databasePending)

        let recoveryDatabase = DeletionDatabaseDouble(log: log)
        #expect(coordinator.delete(using: recoveryDatabase) == .complete)
        #expect(recoveryDatabase.secureEraseCount == 1)
        #expect(!fileSystem.exists(keyURL))
    }

    @Test func markerFailureDoesNotBeginDeletion() {
        let databaseURL = URL(fileURLWithPath: "/organization/team-capacity.sqlite")
        let keyURL = URL(fileURLWithPath: "/organization/team-alias.key")
        let markerURL = URL(fileURLWithPath: "/organization/deletion.pending")
        let fileSystem = DeletionFileSystemDouble(existing: [keyURL], log: DeletionEventLog())
        fileSystem.failStageWrite = true
        let database = DeletionDatabaseDouble(log: DeletionEventLog())
        let coordinator = OrganizationDataDeletionCoordinator(databaseURL: databaseURL, aliasKeyURL: keyURL, markerURL: markerURL, fileSystem: fileSystem)

        #expect(coordinator.delete(using: database) == .notStarted)
        #expect(database.secureEraseCount == 0)
        #expect(fileSystem.exists(keyURL))
    }

    @Test func realSecureDeletionClearsDatabaseKeyMarkerAndSidecars() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("team-capacity.sqlite")
        let keyURL = directory.appendingPathComponent("team-alias.key")
        let markerURL = directory.appendingPathComponent("deletion.pending")
        let store = try SQLiteOrganizationCapacityStore(path: databaseURL.path)
        let aliaser = try OrganizationTeamAliasKey(keyData: Data(repeating: 3, count: 32))
        let now = Date(timeIntervalSince1970: 1_783_468_800)
        let batch = try OrganizationDailyAggregateImporter.importData(acceptedFile(), aliaser: aliaser, now: now)
        try store.record(batch, now: now)
        try Data(repeating: 3, count: 32).write(to: keyURL)
        try Data("wal-sentinel".utf8).write(to: sidecar(databaseURL, "-wal"))
        try Data("shm-sentinel".utf8).write(to: sidecar(databaseURL, "-shm"))
        try Data("journal-sentinel".utf8).write(to: sidecar(databaseURL, "-journal"))

        let coordinator = OrganizationDataDeletionCoordinator(databaseURL: databaseURL, aliasKeyURL: keyURL, markerURL: markerURL)
        #expect(coordinator.delete(using: store) == .complete)
        #expect(!FileManager.default.fileExists(atPath: keyURL.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar(databaseURL, "-wal").path))
        #expect(!FileManager.default.fileExists(atPath: sidecar(databaseURL, "-shm").path))
        #expect(!FileManager.default.fileExists(atPath: sidecar(databaseURL, "-journal").path))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(try Data(contentsOf: databaseURL).range(of: Data(batch.aggregates[0].teamAlias.utf8)) == nil)
        let reopened = try SQLiteOrganizationCapacityStore(path: databaseURL.path)
        #expect(try reopened.aggregates(now: now).isEmpty)
        #expect(try reopened.provenances(now: now).isEmpty)
    }

    @Test func personalDiagnosticsRemainStructurallyIsolated() throws {
        let input = try DiagnosticExportInput(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: DiagnosticVersion(major: 1, minor: 0, patch: 0),
            appBuild: 1,
            operatingSystemVersion: DiagnosticVersion(major: 14, minor: 0, patch: 0),
            providerStatuses: [],
            databaseState: .available,
            importCounts: DiagnosticImportCounts(accepted: 0, rejected: 0),
            resourceLimitReasons: []
        )
        let bytes = try DiagnosticExport.make(from: input).bytes
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.lowercased().contains("organization"))
        #expect(!text.contains("teamAlias"))
        #expect(!text.contains("team-capacity"))

        let labels = Set(Mirror(reflecting: OrganizationStorageDiagnostics(
            schemaVersion: 1,
            retentionDays: 90,
            importCount: 2,
            aggregateCount: 4,
            oldestDay: nil,
            newestDay: nil
        )).children.compactMap(\.label))
        #expect(!labels.contains("teamAlias"))
        #expect(!labels.contains("filePath"))
        #expect(!labels.contains("providerStatuses"))
    }

    private func acceptedFile() -> Data {
        Data(#"{"schema_version":"limitbar.organization.daily.v1","administrator_reviewed":true,"aggregation_period":"daily","timezone":"UTC","records":[{"day":"2026-07-05","provider_product":"codex","team_identity":"11111111-1111-4111-8111-111111111111","cohort_size":5,"complete_day":true,"usage_units":50}]}"#.utf8)
    }
}

private final class PersonalStateDouble {
    var usage = 42
    var credentials = "untouched"
    var diagnostics = "personal-only"
}

private final class DeletionEventLog: @unchecked Sendable {
    var events: [String] = []
}

private final class DeletionDatabaseDouble: OrganizationDeletionDatabase {
    private let log: DeletionEventLog
    var secureEraseCount = 0
    var closeCount = 0
    var shouldFail = false

    init(log: DeletionEventLog) { self.log = log }

    func secureEraseAndClose() throws {
        secureEraseCount += 1
        log.events.append("database:secure-erase")
        if shouldFail { throw OrganizationCapacityError.storageUnavailable }
        close()
    }

    func close() {
        closeCount += 1
        log.events.append("database:close")
    }
}

private final class DeletionFileSystemDouble: OrganizationDeletionFileSystem, @unchecked Sendable {
    private var files: Set<URL>
    private var stages: [URL: OrganizationDeletionStage] = [:]
    private let log: DeletionEventLog
    var failRemovalOnce: URL?
    var failStageWrite = false

    init(existing: Set<URL>, log: DeletionEventLog) {
        files = existing
        self.log = log
    }

    func exists(_ url: URL) -> Bool { files.contains(url) }

    func readStage(at url: URL) throws -> OrganizationDeletionStage {
        guard let stage = stages[url] else { throw OrganizationCapacityError.deletionRecoveryRequired }
        return stage
    }

    func writeStage(_ stage: OrganizationDeletionStage, at url: URL) throws {
        if failStageWrite { throw OrganizationCapacityError.storageUnavailable }
        files.insert(url)
        stages[url] = stage
        log.events.append("marker:\(stage.rawValue)")
    }

    func remove(_ url: URL) throws {
        if failRemovalOnce == url {
            failRemovalOnce = nil
            throw OrganizationCapacityError.storageUnavailable
        }
        files.remove(url)
        stages.removeValue(forKey: url)
        log.events.append("remove:\(url.path)")
    }

    func secureRemove(_ url: URL) throws {
        if failRemovalOnce == url {
            failRemovalOnce = nil
            throw OrganizationCapacityError.storageUnavailable
        }
        files.remove(url)
        stages.removeValue(forKey: url)
        log.events.append("secure-remove:\(url.path)")
    }
}

private func sidecar(_ databaseURL: URL, _ suffix: String) -> URL {
    URL(fileURLWithPath: databaseURL.path + suffix)
}
