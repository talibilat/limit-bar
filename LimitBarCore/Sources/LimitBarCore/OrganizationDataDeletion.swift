import Foundation

public enum OrganizationDeletionStage: String, Codable, Equatable, Sendable {
    case databasePending = "database_pending"
    case filesPending = "files_pending"
}

public enum OrganizationDeletionOutcome: Equatable, Sendable {
    case complete
    case notStarted
    case recoveryRequired(OrganizationDeletionStage)
}

public protocol OrganizationDeletionDatabase: AnyObject {
    func secureEraseAndClose() throws
    func close()
}

extension SQLiteOrganizationCapacityStore: OrganizationDeletionDatabase {}

public protocol OrganizationDeletionFileSystem: Sendable {
    func exists(_ url: URL) -> Bool
    func readStage(at url: URL) throws -> OrganizationDeletionStage
    func writeStage(_ stage: OrganizationDeletionStage, at url: URL) throws
    func remove(_ url: URL) throws
    func secureRemove(_ url: URL) throws
}

public final class FoundationOrganizationDeletionFileSystem: OrganizationDeletionFileSystem, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    public func readStage(at url: URL) throws -> OrganizationDeletionStage {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...64).contains(size) else {
            throw OrganizationCapacityError.deletionRecoveryRequired
        }
        let data = try Data(contentsOf: url, options: .uncached)
        guard let value = String(data: data, encoding: .utf8),
              let stage = OrganizationDeletionStage(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OrganizationCapacityError.deletionRecoveryRequired
        }
        return stage
    }

    public func writeStage(_ stage: OrganizationDeletionStage, at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(stage.rawValue)\n".utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    public func remove(_ url: URL) throws {
        guard exists(url) else { return }
        try fileManager.removeItem(at: url)
    }

    public func secureRemove(_ url: URL) throws {
        guard exists(url) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
            throw OrganizationCapacityError.deletionRecoveryRequired
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seek(toOffset: 0)
            let zeroes = Data(repeating: 0, count: 64 * 1_024)
            var remaining = size
            while remaining > 0 {
                let count = min(remaining, zeroes.count)
                try handle.write(contentsOf: zeroes.prefix(count))
                remaining -= count
            }
            try handle.synchronize()
            try handle.close()
            try fileManager.removeItem(at: url)
        } catch {
            try? handle.close()
            throw error
        }
    }
}

public struct OrganizationDataDeletionCoordinator: Sendable {
    private let databaseURL: URL
    private let aliasKeyURL: URL
    private let markerURL: URL
    private let fileSystem: any OrganizationDeletionFileSystem

    public init(
        databaseURL: URL,
        aliasKeyURL: URL,
        markerURL: URL,
        fileSystem: any OrganizationDeletionFileSystem = FoundationOrganizationDeletionFileSystem()
    ) {
        self.databaseURL = databaseURL
        self.aliasKeyURL = aliasKeyURL
        self.markerURL = markerURL
        self.fileSystem = fileSystem
    }

    public var pendingStage: OrganizationDeletionStage? {
        guard fileSystem.exists(markerURL) else { return nil }
        return (try? fileSystem.readStage(at: markerURL)) ?? .databasePending
    }

    public func delete(using database: any OrganizationDeletionDatabase) -> OrganizationDeletionOutcome {
        let stage: OrganizationDeletionStage
        if fileSystem.exists(markerURL) {
            if let existing = try? fileSystem.readStage(at: markerURL) {
                stage = existing
            } else {
                do {
                    try fileSystem.writeStage(.databasePending, at: markerURL)
                    stage = .databasePending
                } catch {
                    database.close()
                    return .recoveryRequired(.databasePending)
                }
            }
        } else {
            do {
                try fileSystem.writeStage(.databasePending, at: markerURL)
                stage = .databasePending
            } catch {
                return .notStarted
            }
        }

        if stage == .databasePending {
            do {
                try database.secureEraseAndClose()
                try fileSystem.writeStage(.filesPending, at: markerURL)
            } catch {
                database.close()
                return .recoveryRequired(.databasePending)
            }
        } else {
            database.close()
        }

        do {
            for url in sidecarURLs { try fileSystem.secureRemove(url) }
            try fileSystem.secureRemove(aliasKeyURL)
            guard sidecarURLs.allSatisfy({ !fileSystem.exists($0) }), !fileSystem.exists(aliasKeyURL) else {
                return .recoveryRequired(.filesPending)
            }
            try fileSystem.remove(markerURL)
            guard !fileSystem.exists(markerURL) else { return .recoveryRequired(.filesPending) }
            return .complete
        } catch {
            return .recoveryRequired(.filesPending)
        }
    }

    private var sidecarURLs: [URL] {
        ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: databaseURL.path + $0) }
    }
}
