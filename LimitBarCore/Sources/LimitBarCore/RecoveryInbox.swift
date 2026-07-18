import CryptoKit
import Darwin
import Foundation
import Security

public enum RecoveryProduct: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
}

public enum RecoveryFailureClass: String, Codable, CaseIterable, Sendable {
    case quotaExhausted = "quota_exhausted"
    case rateLimited = "rate_limited"
}

public enum RecoveryQuotaWindowKind: String, Codable, CaseIterable, Sendable {
    case session
    case weekly

    var capacityKind: CapacityQuotaWindowKind {
        switch self {
        case .session: .session
        case .weekly: .weekly
        }
    }
}

public struct RecoveryCheckpoint: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let product: RecoveryProduct
    public let sessionReference: String
    public let workspaceFingerprint: String
    public let clientVersion: String
    public let failureClass: RecoveryFailureClass
    public let windowKind: RecoveryQuotaWindowKind
    public let resetBoundary: Date
    public let createdAt: Date

    public init(
        product: RecoveryProduct,
        sessionReference: String,
        workspaceFingerprint: String,
        clientVersion: String,
        failureClass: RecoveryFailureClass,
        windowKind: RecoveryQuotaWindowKind,
        resetBoundary: Date,
        createdAt: Date
    ) {
        schemaVersion = Self.schemaVersion
        self.product = product
        self.sessionReference = sessionReference
        self.workspaceFingerprint = workspaceFingerprint
        self.clientVersion = clientVersion
        self.failureClass = failureClass
        self.windowKind = windowKind
        self.resetBoundary = resetBoundary
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case product
        case sessionReference = "session_reference"
        case workspaceFingerprint = "workspace_fingerprint"
        case clientVersion = "client_version"
        case failureClass = "failure_class"
        case windowKind = "window_kind"
        case resetBoundary = "reset_boundary"
        case createdAt = "created_at"
    }
}

public enum RecoveryCheckpointError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case prohibitedField
    case invalidValue
    case tooLarge
}

public enum RecoveryCheckpointCodec {
    public static let maximumBytes = 8 * 1024
    private static let keys: Set<String> = [
        "schema_version", "product", "session_reference", "workspace_fingerprint",
        "client_version", "failure_class", "window_kind", "reset_boundary", "created_at",
    ]

    public static func encode(_ checkpoint: RecoveryCheckpoint) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(checkpoint)
    }

    public static func decode(_ data: Data) throws -> RecoveryCheckpoint {
        guard !data.isEmpty else { throw RecoveryCheckpointError.malformed }
        guard data.count <= maximumBytes else { throw RecoveryCheckpointError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecoveryCheckpointError.malformed
        }
        let supplied = Set(object.keys)
        guard supplied.isSubset(of: keys) else { throw RecoveryCheckpointError.prohibitedField }
        guard supplied == keys else { throw RecoveryCheckpointError.malformed }
        guard let version = object["schema_version"] as? Int else { throw RecoveryCheckpointError.malformed }
        guard version == RecoveryCheckpoint.schemaVersion else { throw RecoveryCheckpointError.unsupportedVersion }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(RecoveryCheckpoint.self, from: data), isValid(checkpoint) else {
            throw RecoveryCheckpointError.invalidValue
        }
        return checkpoint
    }

    private static func isValid(_ checkpoint: RecoveryCheckpoint) -> Bool {
        let opaque = checkpoint.sessionReference
        let version = checkpoint.clientVersion
        let fingerprint = checkpoint.workspaceFingerprint
        return opaque.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-8][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
            && version.range(of: #"^[0-9]+(\.[0-9]+){1,3}([+-][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
            && fingerprint.range(of: #"^hmac-sha256-v1:[0-9a-f]{64}$"#, options: .regularExpression) != nil
            && checkpoint.createdAt.timeIntervalSince1970.isFinite
            && checkpoint.resetBoundary.timeIntervalSince1970.isFinite
            && checkpoint.resetBoundary > checkpoint.createdAt
    }
}

public enum RecoveryWorkspaceState: String, Codable, Equatable, Sendable {
    case unknown
    case unchanged
    case changed
    case deleted
}

public enum RecoveryUnavailableReason: String, Codable, Equatable, Sendable {
    case staleCapacityEvidence = "stale_capacity_evidence"
    case missingCapacityEvidence = "missing_capacity_evidence"
    case changedResetBoundary = "changed_reset_boundary"
    case providerIncident = "provider_incident"
    case workspaceUnavailable = "workspace_unavailable"
    case sessionExpired = "session_expired"
    case sessionRevalidationRequired = "session_revalidation_required"
    case unsupportedClient = "unsupported_client"
    case resumeCommandUnavailable = "resume_command_unavailable"
}

public enum RecoveryState: Codable, Equatable, Sendable {
    case waiting
    case readyForReview
    case changedWorkspace
    case unavailable(RecoveryUnavailableReason)
    case expired
    case dismissed
    case resumed
}

public struct RecoveryCapacityEvidence: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case missing
        case stale
        case fresh
    }

    public let availability: Availability
    public let product: RecoveryProduct
    public let windowKind: RecoveryQuotaWindowKind
    public let percentageUsed: Double?
    public let observedAt: Date?
    public let expiresAt: Date?
    public let resetBoundary: Date?
    public let incidentActive: Bool

    public init(
        availability: Availability,
        product: RecoveryProduct,
        windowKind: RecoveryQuotaWindowKind,
        percentageUsed: Double? = nil,
        observedAt: Date? = nil,
        expiresAt: Date? = nil,
        resetBoundary: Date? = nil,
        incidentActive: Bool = false
    ) {
        self.availability = availability
        self.product = product
        self.windowKind = windowKind
        self.percentageUsed = percentageUsed
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.resetBoundary = resetBoundary
        self.incidentActive = incidentActive
    }

    public static func from(
        _ publication: CapacityPublication,
        product: RecoveryProduct,
        windowKind: RecoveryQuotaWindowKind,
        now: Date
    ) -> Self {
        let capacityProduct: CapacityProviderProduct = product == .claudeCode ? .claudeCode : .codex
        let relevant = publication.observations.filter {
            $0.product == capacityProduct && $0.windowKind == windowKind.capacityKind
        }
        let incident = publication.incidents.contains {
            $0.product == capacityProduct
                && $0.observedAt.timeIntervalSince1970.isFinite
                && $0.observedAt <= now
                && $0.expiresAt >= now
        }
        guard !relevant.isEmpty else {
            return Self(availability: .missing, product: product, windowKind: windowKind, incidentActive: incident)
        }
        let maximumAge = capacityProduct == .claudeCode
            ? QuotaObservationAdapter.claudeMaximumAge
            : QuotaObservationAdapter.codexMaximumAge
        guard let observation = relevant.filter({
            $0.percentageUsed.isFinite && (0...100).contains($0.percentageUsed)
                && $0.observedAt <= now && now.timeIntervalSince($0.observedAt) <= maximumAge
                && $0.expiresAt >= now && $0.expiresAt <= $0.observedAt.addingTimeInterval(maximumAge)
                && $0.resetBoundary > now
        }).max(by: { $0.percentageUsed < $1.percentageUsed }) else {
            return Self(availability: .stale, product: product, windowKind: windowKind, incidentActive: incident)
        }
        return Self(
            availability: .fresh,
            product: product,
            windowKind: windowKind,
            percentageUsed: observation.percentageUsed,
            observedAt: observation.observedAt,
            expiresAt: observation.expiresAt,
            resetBoundary: observation.resetBoundary,
            incidentActive: incident
        )
    }
}

public enum RecoverySessionState: Equatable, Sendable {
    case revalidationRequired
    case confirmed
    case expired
}

public struct RecoveryReviewContext: Equatable, Sendable {
    public var workspace: RecoveryWorkspaceState
    public var session: RecoverySessionState
    public var clientSupported: Bool
    public var resumeCommandAvailable: Bool

    public init(
        workspace: RecoveryWorkspaceState = .unknown,
        session: RecoverySessionState = .revalidationRequired,
        clientSupported: Bool = true,
        resumeCommandAvailable: Bool = true
    ) {
        self.workspace = workspace
        self.session = session
        self.clientSupported = clientSupported
        self.resumeCommandAvailable = resumeCommandAvailable
    }
}

public enum RecoveryStateMachine {
    public static let expirationAge: TimeInterval = 14 * 24 * 60 * 60
    public static let retentionAge: TimeInterval = 30 * 24 * 60 * 60

    public static func evaluate(
        checkpoint: RecoveryCheckpoint,
        current: RecoveryState,
        capacity: RecoveryCapacityEvidence,
        review: RecoveryReviewContext,
        now: Date
    ) -> RecoveryState {
        if current == .dismissed || current == .resumed { return current }
        if current == .unavailable(.sessionExpired) { return current }
        if now.timeIntervalSince(checkpoint.createdAt) > expirationAge { return .expired }
        if review.workspace == .deleted { return .unavailable(.workspaceUnavailable) }
        guard now >= checkpoint.resetBoundary else {
            if capacity.availability == .fresh,
               let boundary = capacity.resetBoundary,
               boundary != checkpoint.resetBoundary {
                return .unavailable(.changedResetBoundary)
            }
            return .waiting
        }
        guard capacity.product == checkpoint.product, capacity.windowKind == checkpoint.windowKind else {
            return .unavailable(.missingCapacityEvidence)
        }
        switch capacity.availability {
        case .missing: return .unavailable(.missingCapacityEvidence)
        case .stale: return .unavailable(.staleCapacityEvidence)
        case .fresh: break
        }
        guard let observedAt = capacity.observedAt,
              let expiresAt = capacity.expiresAt,
              let boundary = capacity.resetBoundary,
              let percentage = capacity.percentageUsed,
              observedAt >= checkpoint.resetBoundary,
              expiresAt >= now,
              boundary > now,
              boundary > checkpoint.resetBoundary else {
            return .unavailable(.changedResetBoundary)
        }
        guard !capacity.incidentActive else { return .unavailable(.providerIncident) }
        guard percentage < CapacityEvaluator.pausePercentage else { return .waiting }
        let qualifiedWorkspaceState: RecoveryState
        switch review.workspace {
        case .unchanged: qualifiedWorkspaceState = .readyForReview
        case .changed: qualifiedWorkspaceState = .changedWorkspace
        case .unknown, .deleted: return .unavailable(.workspaceUnavailable)
        }
        if !review.clientSupported { return .unavailable(.unsupportedClient) }
        if review.session == .expired { return .unavailable(.sessionExpired) }
        if review.session == .revalidationRequired { return .unavailable(.sessionRevalidationRequired) }
        if !review.resumeCommandAvailable { return .unavailable(.resumeCommandUnavailable) }
        return qualifiedWorkspaceState
    }
}

public struct RecoveryInboxItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let checkpoint: RecoveryCheckpoint
    public var state: RecoveryState
    public var updatedAt: Date
    public var notificationDeliveredAt: Date?

    public init(
        id: String,
        checkpoint: RecoveryCheckpoint,
        state: RecoveryState,
        updatedAt: Date,
        notificationDeliveredAt: Date? = nil
    ) {
        self.id = id
        self.checkpoint = checkpoint
        self.state = state
        self.updatedAt = updatedAt
        self.notificationDeliveredAt = notificationDeliveredAt
    }
}

public enum RecoverySubmissionResult: String, Codable, Equatable, Sendable {
    case accepted
    case duplicate
    case conflict
}

public enum RecoveryInboxStoreError: Error, Equatable {
    case unavailable
    case malformed
}

public final class RecoveryInboxStore: @unchecked Sendable {
    public static let maximumCount = 100
    private let destination: URL
    private let lock = NSLock()

    public init(destination: URL) {
        self.destination = destination
    }

    public static func production(fileManager: FileManager = .default) throws -> RecoveryInboxStore {
        RecoveryInboxStore(destination: try LimitBarFileLocations.production(fileManager: fileManager).recoveryInbox)
    }

    public func all(now: Date = Date()) throws -> [RecoveryInboxItem] {
        return try synchronized {
            var items = try load()
            items = retained(items, now: now)
            try save(items)
            return items.sorted { $0.checkpoint.createdAt > $1.checkpoint.createdAt }
        }
    }

    public func submit(_ checkpoint: RecoveryCheckpoint, now: Date = Date()) throws -> RecoverySubmissionResult {
        _ = try RecoveryCheckpointCodec.decode(RecoveryCheckpointCodec.encode(checkpoint))
        return try synchronized {
            var items = retained(try load(), now: now)
            if items.contains(where: { $0.checkpoint == checkpoint }) { return RecoverySubmissionResult.duplicate }
            if items.contains(where: {
                $0.checkpoint.product == checkpoint.product
                    && $0.checkpoint.sessionReference == checkpoint.sessionReference
                    && $0.checkpoint.resetBoundary == checkpoint.resetBoundary
            }) {
                return RecoverySubmissionResult.conflict
            }
            items.append(RecoveryInboxItem(
                id: UUID().uuidString.lowercased(),
                checkpoint: checkpoint,
                state: .waiting,
                updatedAt: now,
                notificationDeliveredAt: nil
            ))
            items = Array(items.sorted { $0.checkpoint.createdAt > $1.checkpoint.createdAt }.prefix(Self.maximumCount))
            try save(items)
            return RecoverySubmissionResult.accepted
        }
    }

    @discardableResult
    public func transition(id: String, to state: RecoveryState, now: Date = Date()) throws -> Bool {
        try synchronized {
            var items = retained(try load(), now: now)
            guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
            guard Self.canTransition(from: items[index].state, to: state) else { return false }
            items[index].state = state
            items[index].updatedAt = now
            try save(items)
            return true
        }
    }

    @discardableResult
    public func delete(id: String, now: Date = Date()) throws -> Bool {
        try synchronized {
            var items = retained(try load(), now: now)
            let previous = items.count
            items.removeAll { $0.id == id }
            guard items.count != previous else { return false }
            try save(items)
            return true
        }
    }

    public func deleteAll() throws {
        try synchronized { try save([]) }
    }

    @discardableResult
    public func markNotificationDelivered(id: String, at date: Date = Date()) throws -> Bool {
        try synchronized {
            var items = retained(try load(), now: date)
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].notificationDeliveredAt == nil else {
                return false
            }
            items[index].notificationDeliveredAt = date
            items[index].updatedAt = date
            try save(items)
            return true
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = destination.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw RecoveryInboxStoreError.unavailable
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        return try operation()
    }

    private func load() throws -> [RecoveryInboxItem] {
        guard FileManager.default.fileExists(atPath: destination.path) else { return [] }
        guard !SecureRegularFile.isSymbolicLink(destination) else { throw RecoveryInboxStoreError.unavailable }
        guard let canonical = SecureRegularFile.canonicalURL(destination) else { throw RecoveryInboxStoreError.unavailable }
        do {
            let handle = try SecureRegularFile.open(canonical)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 512 * 1024 + 1) ?? Data()
            guard data.count <= 512 * 1024 else { throw RecoveryInboxStoreError.malformed }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([RecoveryInboxItem].self, from: data)
            for item in items {
                _ = try RecoveryCheckpointCodec.decode(RecoveryCheckpointCodec.encode(item.checkpoint))
            }
            return items
        } catch let error as RecoveryInboxStoreError {
            throw error
        } catch {
            throw RecoveryInboxStoreError.malformed
        }
    }

    private func save(_ items: [RecoveryInboxItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".recovery-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RecoveryInboxStoreError.unavailable
        }
        let result: Int32 = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return Darwin.rename(source, target)
            }
        }
        if result != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw RecoveryInboxStoreError.unavailable
        }
    }

    private func retained(_ items: [RecoveryInboxItem], now: Date) -> [RecoveryInboxItem] {
        Array(items.filter {
            now.timeIntervalSince($0.checkpoint.createdAt) <= RecoveryStateMachine.retentionAge
        }.sorted {
            $0.checkpoint.createdAt > $1.checkpoint.createdAt
        }.prefix(Self.maximumCount))
    }

    private static func canTransition(from: RecoveryState, to: RecoveryState) -> Bool {
        if from == .dismissed || from == .resumed || from == .expired { return false }
        if to == .resumed { return from == .readyForReview || from == .changedWorkspace }
        if to == .dismissed || to == .expired { return true }
        return true
    }
}

public enum RecoveryWorkspaceFingerprint {
    public static let prefix = "hmac-sha256-v1:"

    public static func make(workspace: URL, key: Data) throws -> String {
        guard key.count == 32 else { throw RecoveryCheckpointError.invalidValue }
        let values = try workspace.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RecoveryCheckpointError.invalidValue }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var authenticator = HMAC<SHA256>(key: SymmetricKey(data: key))
        try update(&authenticator, label: "head", command: ["rev-parse", "--verify", "HEAD"], workspace: root)
        try update(&authenticator, label: "staged", command: ["diff", "--cached", "--no-ext-diff", "--binary", "--full-index"], workspace: root)
        try update(&authenticator, label: "working", command: ["diff", "--no-ext-diff", "--binary", "--full-index"], workspace: root)
        let untracked = try git(["ls-files", "--others", "--exclude-standard", "-z"], workspace: root)
        authenticator.update(data: Data("untracked\0".utf8))
        for pathData in untracked.split(separator: 0).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            authenticator.update(data: Data(pathData))
            authenticator.update(data: Data([0]))
            guard let path = String(data: Data(pathData), encoding: .utf8) else {
                throw RecoveryCheckpointError.invalidValue
            }
            let file = root.appendingPathComponent(path)
            var status = stat()
            let statusResult = file.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &status)
            }
            guard statusResult == 0 else { throw RecoveryCheckpointError.invalidValue }
            authenticator.update(data: Data("\(status.st_mode):\(status.st_size)\0".utf8))
            if status.st_mode & S_IFMT == S_IFLNK {
                var target = [UInt8](repeating: 0, count: Int(PATH_MAX))
                let count = file.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return -1 }
                    return readlink(path, &target, target.count)
                }
                guard count >= 0 else { throw RecoveryCheckpointError.invalidValue }
                authenticator.update(data: Data(target.prefix(count)))
                authenticator.update(data: Data([0]))
                continue
            }
            guard status.st_mode & S_IFMT == S_IFREG else { throw RecoveryCheckpointError.invalidValue }
            let handle = try SecureRegularFile.open(file)
            defer { try? handle.close() }
            var total = 0
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                total += chunk.count
                guard total <= 256 * 1024 * 1024 else { throw RecoveryCheckpointError.tooLarge }
                authenticator.update(data: chunk)
            }
            authenticator.update(data: Data([0]))
        }
        let digest = authenticator.finalize()
        return prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func loadOrCreateKey(at destination: URL) throws -> Data {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let canonicalURL = SecureRegularFile.canonicalURL(destination) else {
                throw RecoveryCheckpointError.invalidValue
            }
            let handle = try SecureRegularFile.open(canonicalURL)
            defer { try? handle.close() }
            let data = try handle.readToEnd() ?? Data()
            guard data.count == 32 else { throw RecoveryCheckpointError.invalidValue }
            return data
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RecoveryCheckpointError.invalidValue
        }
        let data = Data(bytes)
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if descriptor < 0 {
            if errno == EEXIST { return try loadOrCreateKey(at: destination) }
            throw RecoveryCheckpointError.invalidValue
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            return data
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func update(
        _ authenticator: inout HMAC<SHA256>,
        label: String,
        command: [String],
        workspace: URL
    ) throws {
        authenticator.update(data: Data((label + "\0").utf8))
        authenticator.update(data: try git(command, workspace: workspace))
        authenticator.update(data: Data([0]))
    }

    private static func git(_ arguments: [String], workspace: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workspace.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 256 * 1024 * 1024 else {
            throw RecoveryCheckpointError.invalidValue
        }
        return data
    }
}

public struct RecoveryReviewedWorkspace: Equatable, Sendable {
    public let canonicalURL: URL
    public let device: UInt64
    public let inode: UInt64
    public let fingerprint: String

    public static func inspect(workspace: URL, key: Data) throws -> Self {
        guard let canonicalURL = SecureRegularFile.canonicalURL(workspace) else {
            throw RecoveryCheckpointError.invalidValue
        }
        var status = stat()
        let result = canonicalURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &status)
        }
        guard result == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw RecoveryCheckpointError.invalidValue
        }
        return Self(
            canonicalURL: canonicalURL,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            fingerprint: try RecoveryWorkspaceFingerprint.make(workspace: canonicalURL, key: key)
        )
    }

    public func revalidated(key: Data) -> RecoveryReviewedWorkspace? {
        guard let current = try? Self.inspect(workspace: canonicalURL, key: key), current == self else { return nil }
        return current
    }
}

public struct RecoveryExecutableIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let sha256: String
}

public struct RecoveryResumeCommand: Equatable, Sendable {
    public let executableURL: URL
    public let executableIdentity: RecoveryExecutableIdentity
    public let arguments: [String]

    public static func documented(for checkpoint: RecoveryCheckpoint, executableURL: URL) throws -> Self {
        let expectedName = checkpoint.product == .claudeCode ? "claude" : "codex"
        guard let canonicalURL = SecureRegularFile.canonicalURL(executableURL),
              canonicalURL.lastPathComponent == expectedName else {
            throw RecoveryCheckpointError.invalidValue
        }
        let identity = try RecoveryExecutableValidator.identity(of: canonicalURL)
        let arguments = checkpoint.product == .claudeCode
            ? ["--resume", checkpoint.sessionReference]
            : ["resume", checkpoint.sessionReference]
        return Self(executableURL: canonicalURL, executableIdentity: identity, arguments: arguments)
    }

    public func isStillValid() -> Bool {
        (try? RecoveryExecutableValidator.identity(of: executableURL)) == executableIdentity
    }

    public var display: String {
        ([executableURL.path] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9._+:/=-]+$"#, options: .regularExpression) != nil { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum RecoveryExecutableValidator {
    public static func identity(of url: URL) throws -> RecoveryExecutableIdentity {
        guard url.path.hasPrefix("/"), !SecureRegularFile.isSymbolicLink(url) else {
            throw RecoveryCheckpointError.invalidValue
        }
        guard let canonicalURL = SecureRegularFile.canonicalURL(url) else {
            throw RecoveryCheckpointError.invalidValue
        }
        let handle = try SecureRegularFile.open(canonicalURL)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o111 != 0 else {
            throw RecoveryCheckpointError.invalidValue
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return RecoveryExecutableIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            size: UInt64(status.st_size),
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}

public enum RecoveryNotificationIdentity {
    public static func identifier(itemID: String) throws -> String {
        guard UUID(uuidString: itemID) != nil else { throw RecoveryCheckpointError.invalidValue }
        return "limitbar.recovery.ready.\(itemID.lowercased())"
    }
}

public enum RecoveryClientSupport {
    public static func isSupported(product: RecoveryProduct, version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, let major = Int(components[0]), let minor = Int(components[1]) else { return false }
        switch product {
        case .claudeCode: return (1...2).contains(major)
        case .codex: return major == 1 || (major == 0 && minor >= 1)
        }
    }
}
