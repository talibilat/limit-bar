import Foundation

// Turns local Codex session files into normalized usage events (timestamp, model, tokens)
// so the Usage and History tabs have data. It reads only token counters and the model
// label. Prompts, code, responses and paths never leave the session files.

public struct CodexUsageEvent: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
}

public enum CodexUsageEventParser {
    /// Parses one session file. The first counter in a file uses the per-call figure, because a
    /// forked session can start from its parent's running total.
    public static func events(from data: Data) -> [CodexUsageEvent] {
        var events: [CodexUsageEvent] = []
        var model = "codex"
        var previous: (input: Int, output: Int)?
        let tokenMarker = Data("token_count".utf8)
        let contextMarker = Data("turn_context".utf8)
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let isToken = line.range(of: tokenMarker) != nil
            let isContext = !isToken && line.range(of: contextMarker) != nil
            guard isToken || isContext,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if isContext, object["type"] as? String == "turn_context" {
                if let value = (payload["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    model = String(value.prefix(200))
                }
                continue
            }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = counters(info["total_token_usage"]),
                  let stamp = (object["timestamp"] as? String).flatMap(parseTimestamp) else { continue }
            let delta: (input: Int, output: Int)
            if let previous {
                let input = total.input - previous.input
                let output = total.output - previous.output
                // A drop means the counter restarted. Skip it and use the new total as the baseline.
                delta = input < 0 || output < 0 ? (0, 0) : (input, output)
            } else {
                delta = counters(info["last_token_usage"]) ?? (0, 0)
            }
            previous = total
            guard delta.input > 0 || delta.output > 0 else { continue }
            events.append(CodexUsageEvent(timestamp: stamp, model: model, inputTokens: delta.input, outputTokens: delta.output))
        }
        return events
    }

    private static func counters(_ value: Any?) -> (input: Int, output: Int)? {
        guard let dictionary = value as? [String: Any],
              let input = (dictionary["input_tokens"] as? NSNumber)?.intValue,
              let output = (dictionary["output_tokens"] as? NSNumber)?.intValue,
              input >= 0, output >= 0 else { return nil }
        return (input, output)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    public static func jsonLine(for event: CodexUsageEvent) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "timestamp": formatter.string(from: event.timestamp),
            "model": event.model,
            "inputTokens": event.inputTokens,
            "outputTokens": event.outputTokens
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Scans the Codex sessions folder and writes `codex-usage-events.jsonl`. It reparses only
/// files whose size or modification date changed since the last scan.
public actor CodexUsageEventExporter {
    private struct Entry {
        let size: Int
        let modified: Date
        let events: [CodexUsageEvent]
    }

    private var cache: [String: Entry] = [:]
    private var lastOutputSignature: String?

    public init() {}

    /// Returns true when the output file was written or already holds the current events.
    @discardableResult
    public func export(
        sessionsDirectory: URL,
        to outputURL: URL,
        now: Date = Date(),
        lookbackDays: Int = 35,
        maximumFileSize: Int = 256 * 1_024 * 1_024
    ) -> Bool {
        let fileManager = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        var seen = Set<String>()
        if let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate, modified >= cutoff,
                      let size = values.fileSize, size <= maximumFileSize else { continue }
                seen.insert(url.path)
                if let entry = cache[url.path], entry.size == size, entry.modified == modified { continue }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                cache[url.path] = Entry(size: size, modified: modified, events: CodexUsageEventParser.events(from: data))
            }
        }
        cache = cache.filter { seen.contains($0.key) }

        let events = cache.values.flatMap(\.events)
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(300) }
            .sorted { $0.timestamp < $1.timestamp }
        let body = events.map(CodexUsageEventParser.jsonLine(for:)).joined(separator: "\n")
        let contents = body.isEmpty ? "" : body + "\n"
        let signature = "\(events.count):\(contents.utf8.count):\(events.last?.timestamp.timeIntervalSince1970 ?? 0)"
        if signature == lastOutputSignature, fileManager.fileExists(atPath: outputURL.path) { return true }
        do {
            try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: outputURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
            lastOutputSignature = signature
            return true
        } catch {
            return false
        }
    }
}
