import Darwin
import Foundation

public struct CollectorPolicy: Equatable, Sendable {
    public var maximumRequestBytes: Int
    public var maximumEventsPerMinute: Int
    public var maximumActiveFileBytes: Int
    public var activeRetention: TimeInterval
    public var maximumArchiveBytes: Int
    public var archiveRetention: TimeInterval
    public var futureTimestampTolerance: TimeInterval

    public init(
        maximumRequestBytes: Int = CollectorSchemaV1.maximumRequestBytes,
        maximumEventsPerMinute: Int = 120,
        maximumActiveFileBytes: Int = 10 * 1_024 * 1_024,
        activeRetention: TimeInterval = 8 * 24 * 60 * 60,
        maximumArchiveBytes: Int = 1_024 * 1_024 * 1_024,
        archiveRetention: TimeInterval = 30 * 24 * 60 * 60,
        futureTimestampTolerance: TimeInterval = 5 * 60
    ) {
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumEventsPerMinute = maximumEventsPerMinute
        self.maximumActiveFileBytes = maximumActiveFileBytes
        self.activeRetention = activeRetention
        self.maximumArchiveBytes = maximumArchiveBytes
        self.archiveRetention = archiveRetention
        self.futureTimestampTolerance = futureTimestampTolerance
    }
}

public enum CollectorWriteResult: Equatable, Sendable {
    case appended
    case duplicate
    case appendedAfterRotation(archiveURL: URL)
}

public enum CollectorWriterError: Error, Equatable, Sendable {
    case invalidPolicy
    case requestTooLarge
    case futureTimestamp
    case eventIDConflict
    case rateLimited
    case outputIsNotRegularFile
    case activeFileTooLargeAfterRetention
    case archiveLimitTooSmall
    case lockFailed
    case readFailed
    case writeFailed
}

public struct CollectorWriter: Sendable {
    private static let maximumReadableFileBytes = 100 * 1_024 * 1_024
    private static let maximumRateStateBytes = 256 * 1_024
    private static let maximumConfigurableEventsPerMinute = 10_000

    public let policy: CollectorPolicy

    public init(policy: CollectorPolicy = CollectorPolicy()) {
        self.policy = policy
    }

    @discardableResult
    public func append(_ event: CollectorEventV1, to outputURL: URL, now: Date = Date()) throws -> CollectorWriteResult {
        try append(CollectorSchemaV1.encode(event), to: outputURL, now: now)
    }

    @discardableResult
    public func append(_ event: CollectorEventV2, to outputURL: URL, now: Date = Date()) throws -> CollectorWriteResult {
        try append(CollectorSchemaV2.encode(event), to: outputURL, now: now)
    }

    @discardableResult
    public func append(_ request: Data, to outputURL: URL, now: Date = Date()) throws -> CollectorWriteResult {
        try validatePolicy()
        guard request.count <= policy.maximumRequestBytes else { throw CollectorWriterError.requestTooLarge }
        let event = try CollectorSchema.decode(request)
        guard event.timestamp <= now.addingTimeInterval(policy.futureTimestampTolerance) else { throw CollectorWriterError.futureTimestamp }
        let canonicalRequest = try CollectorSchema.encode(event)

        let fileManager = FileManager.default
        let directory = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw CollectorWriterError.writeFailed
        }

        let lockDescriptor = try acquireLock(for: outputURL)
        defer {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }

        let existing = try readRegularFileIfPresent(at: outputURL, maximumBytes: Self.maximumReadableFileBytes)
        try securePermissionsIfPresent(at: outputURL)
        try securePermissionsIfPresent(at: rateStateURL(for: outputURL))
        switch existingEvent(matching: event, in: existing) {
        case .same: return .duplicate
        case .different: throw CollectorWriterError.eventIDConflict
        case .absent: break
        }

        var times = try readRateState(for: outputURL)
        let cutoff = now.timeIntervalSince1970 - 60
        times.removeAll { $0 <= cutoff || $0 > now.timeIntervalSince1970 + 60 }
        guard times.count < policy.maximumEventsPerMinute else { throw CollectorWriterError.rateLimited }

        let candidate = appendingJSONLLine(canonicalRequest, to: existing)
        let result: CollectorWriteResult
        if candidate.count <= policy.maximumActiveFileBytes {
            try persist(candidate, previousActiveData: existing, rateTimes: times + [now.timeIntervalSince1970], outputURL: outputURL)
            result = .appended
        } else {
            let retained = retainedLines(in: existing, since: now.addingTimeInterval(-policy.activeRetention))
            let rotatedCandidate = appendingJSONLLine(canonicalRequest, to: retained)
            guard rotatedCandidate.count <= policy.maximumActiveFileBytes else { throw CollectorWriterError.activeFileTooLargeAfterRetention }
            guard existing.count <= policy.maximumArchiveBytes else { throw CollectorWriterError.archiveLimitTooSmall }
            try pruneArchives(for: outputURL, addingBytes: existing.count, now: now)
            let archiveURL = archiveURL(for: outputURL, event: event, now: now)
            try atomicWrite(existing, to: archiveURL)
            do {
                try persist(rotatedCandidate, previousActiveData: existing, rateTimes: times + [now.timeIntervalSince1970], outputURL: outputURL)
            } catch {
                try? FileManager.default.removeItem(at: archiveURL)
                throw error
            }
            result = .appendedAfterRotation(archiveURL: archiveURL)
        }
        return result
    }

    private enum ExistingEventMatch {
        case absent
        case same
        case different
    }

    private func validatePolicy() throws {
        guard policy.maximumRequestBytes > 0,
              policy.maximumRequestBytes <= CollectorSchemaV1.maximumRequestBytes,
              policy.maximumEventsPerMinute > 0,
              policy.maximumEventsPerMinute <= Self.maximumConfigurableEventsPerMinute,
              policy.maximumActiveFileBytes > 0,
              policy.maximumActiveFileBytes <= Self.maximumReadableFileBytes,
              policy.activeRetention >= 0,
              policy.maximumArchiveBytes > 0,
              policy.archiveRetention >= 0,
              policy.futureTimestampTolerance >= 0 else { throw CollectorWriterError.invalidPolicy }
    }

    private func acquireLock(for outputURL: URL) throws -> Int32 {
        let lockURL = URL(fileURLWithPath: outputURL.path + ".collector.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CollectorWriterError.lockFailed }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            Darwin.close(descriptor)
            throw CollectorWriterError.lockFailed
        }
        return descriptor
    }

    private func existingEvent(matching submittedEvent: CollectorEvent, in data: Data) -> ExistingEventMatch {
        let expectedID = submittedEvent.eventID.uuidString.lowercased()
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let value = object["eventID"] as? String,
                  value.lowercased() == expectedID else { continue }
            guard let event = try? CollectorSchema.decode(Data(line)) else { return .different }
            return event == submittedEvent ? .same : .different
        }
        return .absent
    }

    private func retainedLines(in data: Data, since cutoff: Date) -> Data {
        var retained = Data()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let lineData = Data(line)
            let timestamp = (try? JSONSerialization.jsonObject(with: lineData) as? [String: Any])
                .flatMap { $0["timestamp"] as? String }
                .flatMap(CollectorSchemaV1.parseTimestamp)
            if timestamp.map({ $0 >= cutoff }) ?? true {
                retained.append(lineData)
                if index < lines.count - 1 { retained.append(0x0A) }
            }
        }
        return retained
    }

    private func appendingJSONLLine(_ line: Data, to existing: Data) -> Data {
        var result = existing
        if !result.isEmpty, result.last != 0x0A { result.append(0x0A) }
        result.append(line)
        result.append(0x0A)
        return result
    }

    private func persist(_ activeData: Data, previousActiveData: Data, rateTimes: [TimeInterval], outputURL: URL) throws {
        try atomicWrite(activeData, to: outputURL)
        do {
            try writeRateState(rateTimes, for: outputURL)
        } catch {
            try? atomicWrite(previousActiveData, to: outputURL)
            throw error
        }
    }

    private func archiveURL(for outputURL: URL, event: CollectorEvent, now: Date) -> URL {
        let suffix = outputURL.pathExtension.isEmpty ? "jsonl" : outputURL.pathExtension
        let name = "\(archivePrefix(for: outputURL))\(Int(now.timeIntervalSince1970)).\(event.eventID.uuidString.lowercased()).\(suffix)"
        return outputURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func pruneArchives(for outputURL: URL, addingBytes: Int, now: Date) throws {
        let directory = outputURL.deletingLastPathComponent()
        let prefix = archivePrefix(for: outputURL)
        let suffix = outputURL.pathExtension.isEmpty ? "jsonl" : outputURL.pathExtension
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                .filter { isArchiveName($0.lastPathComponent, prefix: prefix, suffix: suffix) }
        } catch {
            throw CollectorWriterError.readFailed
        }
        var archives: [(url: URL, bytes: Int, modified: Date)] = []
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let bytes = values.fileSize, let modified = values.contentModificationDate else { continue }
                archives.append((url, bytes, modified))
            } catch {
                throw CollectorWriterError.readFailed
            }
        }
        archives.sort { ($0.modified, $0.url.lastPathComponent) < ($1.modified, $1.url.lastPathComponent) }
        var total = archives.reduce(0) { $0 + $1.bytes }
        let expiry = now.addingTimeInterval(-policy.archiveRetention)
        for archive in archives where archive.modified < expiry {
            try removeArchive(archive.url)
            total -= archive.bytes
        }
        for archive in archives where FileManager.default.fileExists(atPath: archive.url.path) && total + addingBytes > policy.maximumArchiveBytes {
            try removeArchive(archive.url)
            total -= archive.bytes
        }
        guard total + addingBytes <= policy.maximumArchiveBytes else { throw CollectorWriterError.archiveLimitTooSmall }
    }

    private func archivePrefix(for outputURL: URL) -> String {
        outputURL.lastPathComponent + ".archive-v1."
    }

    private func isArchiveName(_ name: String, prefix: String, suffix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let components = name.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              Int(components[0]) != nil,
              UUID(uuidString: String(components[1])) != nil else { return false }
        return components[2] == Substring(suffix)
    }

    private func removeArchive(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CollectorWriterError.writeFailed
        }
    }

    private func rateStateURL(for outputURL: URL) -> URL {
        URL(fileURLWithPath: outputURL.path + ".collector-rate-v1.json")
    }

    private func readRateState(for outputURL: URL) throws -> [TimeInterval] {
        let data = try readRegularFileIfPresent(at: rateStateURL(for: outputURL), maximumBytes: Self.maximumRateStateBytes)
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([TimeInterval].self, from: data)
        } catch {
            throw CollectorWriterError.readFailed
        }
    }

    private func writeRateState(_ times: [TimeInterval], for outputURL: URL) throws {
        do {
            try atomicWrite(JSONEncoder().encode(times), to: rateStateURL(for: outputURL))
        } catch let error as CollectorWriterError {
            throw error
        } catch {
            throw CollectorWriterError.writeFailed
        }
    }

    private func readRegularFileIfPresent(at url: URL, maximumBytes: Int) throws -> Data {
        guard let status = try fileStatus(at: url) else { return Data() }
        guard status.st_mode & S_IFMT == S_IFREG else { throw CollectorWriterError.outputIsNotRegularFile }
        guard status.st_size >= 0, status.st_size <= maximumBytes else { throw CollectorWriterError.readFailed }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CollectorWriterError.readFailed
        }
    }

    private func securePermissionsIfPresent(at url: URL) throws {
        guard let status = try fileStatus(at: url) else { return }
        guard status.st_mode & S_IFMT == S_IFREG else { throw CollectorWriterError.outputIsNotRegularFile }
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw CollectorWriterError.writeFailed }
    }

    private func fileStatus(at url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 { return status }
        if errno == ENOENT { return nil }
        throw CollectorWriterError.readFailed
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        var template = Array((url.path + ".collector-tmp.XXXXXX").utf8CString)
        var descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw CollectorWriterError.writeFailed }
        let temporaryPath = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if shouldRemoveTemporaryFile { unlink(temporaryPath) }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw CollectorWriterError.writeFailed }
        let wroteAllBytes = data.withUnsafeBytes { buffer -> Bool in
            guard var address = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                remaining -= written
                address = address.advanced(by: written)
            }
            return true
        }
        guard wroteAllBytes else { throw CollectorWriterError.writeFailed }
        var syncResult: Int32
        repeat { syncResult = fsync(descriptor) } while syncResult < 0 && errno == EINTR
        guard syncResult == 0 else { throw CollectorWriterError.writeFailed }
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else { throw CollectorWriterError.writeFailed }
        guard rename(temporaryPath, url.path) == 0 else { throw CollectorWriterError.writeFailed }
        shouldRemoveTemporaryFile = false
    }
}
