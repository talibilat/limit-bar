import Foundation

// Turns local Codex session files into normalized usage events (timestamp, model, tokens)
// so the Usage and History tabs have data. It reads only token counters and the model
// label. Prompts, code, responses and paths never leave the session files.

public struct CodexDailyUsage: Equatable, Sendable {
    public let dayStart: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
}

public struct CodexUsageEvent: Equatable, Sendable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
}

/// Mirrors T3 Code's Codex reader. Each `token_count` event's `last_token_usage` is one request.
/// Cumulative totals confirm it, repeated ticks and replays are dropped, and history that a forked
/// session copies from its parent is ignored because the parent already counted it.
public enum CodexUsageEventParser {
    private struct Counters: Equatable {
        var input = 0, cached = 0, cacheWrite = 0, output = 0, reasoning = 0, total = 0

        init?(_ value: Any?) {
            guard let raw = value as? [String: Any],
                  let input = (raw["input_tokens"] as? NSNumber)?.intValue,
                  let output = (raw["output_tokens"] as? NSNumber)?.intValue else { return nil }
            self.init(
                input: input,
                cached: (raw["cached_input_tokens"] as? NSNumber)?.intValue ?? 0,
                cacheWrite: (raw["cache_write_input_tokens"] as? NSNumber)?.intValue ?? 0,
                output: output,
                reasoning: (raw["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0,
                total: (raw["total_tokens"] as? NSNumber)?.intValue ?? input + output
            )
        }

        init?(input: Int, cached: Int, cacheWrite: Int, output: Int, reasoning: Int, total: Int) {
            guard input >= 0, cached >= 0, cacheWrite >= 0, output >= 0, reasoning >= 0, total >= 0,
                  cached + cacheWrite <= input, reasoning <= output, total >= input + output else { return nil }
            self.input = input; self.cached = cached; self.cacheWrite = cacheWrite
            self.output = output; self.reasoning = reasoning; self.total = total
        }

        var fields: [Int] { [input, cached, cacheWrite, output, reasoning, total] }

        func combined(_ other: Counters, _ sign: Int) -> Counters? {
            Counters(
                input: input + sign * other.input, cached: cached + sign * other.cached,
                cacheWrite: cacheWrite + sign * other.cacheWrite, output: output + sign * other.output,
                reasoning: reasoning + sign * other.reasoning, total: total + sign * other.total
            )
        }
    }

    private struct Pending {
        let timestamp: Date
        let model: String
        var usage: Counters
    }

    private struct State {
        var model = ""
        var sawSessionMeta = false
        var suppressingForkCopies = false
        var forkCopyAnchor = Date.distantPast
        var lastCumulative: Counters?
        var lastSignature: [Int]?
        var sequenceStart: String?
        var pending: [Pending]?
    }

    private static let forkCopyMaxGap: TimeInterval = 1

    public static func events(from data: Data) -> [CodexUsageEvent] {
        var state = State()
        var events: [CodexUsageEvent] = []
        let markers = ["session_meta", "turn_context", "token_usage_record", "token_count"].map { Data($0.utf8) }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard markers.contains(where: { line.range(of: $0) != nil }),
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            events.append(contentsOf: process(object, payload, &state))
        }
        return events
    }

    private static func process(_ object: [String: Any], _ payload: [String: Any], _ state: inout State) -> [CodexUsageEvent] {
        let type = object["type"] as? String
        let stamp = (object["timestamp"] as? String).flatMap(parseTimestamp)

        if type == "session_meta" {
            // Only the first meta identifies this session. Copied ancestor metas are ignored.
            guard !state.sawSessionMeta else { return [] }
            state.sawSessionMeta = true
            if let stamp, isForked(payload) {
                state.suppressingForkCopies = true
                state.forkCopyAnchor = stamp
            }
            return []
        }
        if type == "turn_context" {
            if let model = (payload["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                state.model = String(model.prefix(200))
            }
            return []
        }
        if type == "token_usage_record" {
            guard let stamp, let usage = Counters(payload["usage"]), !state.model.isEmpty,
                  !isForkCopy(&state, stamp) else { return [] }
            state.pending = (state.pending ?? []) + [Pending(timestamp: stamp, model: state.model, usage: usage)]
            return []
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let stamp, !state.model.isEmpty else { return [] }

        let last = Counters(info["last_token_usage"])
        let rawCumulative = info["total_token_usage"]
        let hasCumulative = rawCumulative != nil && !(rawCumulative is NSNull)
        let cumulative = hasCumulative ? Counters(rawCumulative) : nil

        if isForkCopy(&state, stamp) {
            // Copied history is already counted in the parent but sets this session's baseline.
            let signature = last?.fields
            if let cumulative { rebase(&state, cumulative) }
            else if !hasCumulative, let last, signature != state.lastSignature {
                state.lastCumulative = (state.lastCumulative ?? Counters(input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0)!).combined(last, 1)
            }
            state.lastSignature = signature
            return []
        }

        let previous = state.lastCumulative
        let pending = state.pending
        if let cumulative { rebase(&state, cumulative) }
        guard let last, !(hasCumulative && cumulative == nil) else { return [] }

        // Zero input and output means a context-size marker, not a request.
        if last.input + last.output == 0 {
            state.lastSignature = nil
            return []
        }
        if let cumulative, let previous, cumulative == previous { return [] }
        guard last.total == last.input + last.output else { return [] }

        var unreported: [Pending] = []
        if let cumulative {
            // A session resumed in a new process restarts its counters at this request.
            let restarted = cumulative == last
            let sequenceStart = "\(stamp.timeIntervalSince1970)|\(last.fields)"
            if restarted, sequenceStart == state.sequenceStart {
                state.lastCumulative = previous
                return []
            }
            let reconciled: Bool
            if let previous {
                reconciled = zip(cumulative.fields, previous.fields).map { $0 - $1 } == last.fields
            } else {
                reconciled = cumulative.combined(last, -1) != nil
            }
            if !restarted, !reconciled {
                guard let bridged = bridge(previous: previous, cumulative: cumulative, last: last, pending: pending) else { return [] }
                unreported = bridged
            }
            if restarted { state.sequenceStart = sequenceStart }
        } else {
            if last.fields == state.lastSignature { return [] }
            guard let advanced = (previous ?? Counters(input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0)!).combined(last, 1) else { return [] }
            state.lastCumulative = advanced
        }
        state.lastSignature = last.fields

        var result = unreported.map { CodexUsageEvent(timestamp: $0.timestamp, model: $0.model, inputTokens: $0.usage.input, outputTokens: $0.usage.output) }
        result.append(CodexUsageEvent(timestamp: stamp, model: state.model, inputTokens: last.input, outputTokens: last.output))
        return result
    }

    private static func rebase(_ state: inout State, _ cumulative: Counters) {
        state.lastCumulative = cumulative
        state.pending = nil
        if cumulative.input + cumulative.output == 0 { state.sequenceStart = nil }
    }

    /// An interrupted turn can end before its last request is reported. Bill those requests only
    /// when the `token_usage_record` lines since the previous snapshot explain the whole gap.
    private static func bridge(previous: Counters?, cumulative: Counters, last: Counters, pending: [Pending]?) -> [Pending]? {
        guard let previous, let pending, let final = pending.last else { return nil }
        let gap = zip(cumulative.fields, previous.fields).map { $0 - $1 }
        var sum = [Int](repeating: 0, count: 6)
        for request in pending { for (index, value) in request.usage.fields.enumerated() { sum[index] += value } }
        guard gap == sum, let remainder = final.usage.combined(last, -1) else { return nil }
        var result = Array(pending.dropLast())
        result.append(Pending(timestamp: final.timestamp, model: final.model, usage: remainder))
        return result.filter { $0.usage.input + $0.usage.output > 0 }
    }

    /// Forks copy and restamp parent history in a burst with gaps under a second.
    private static func isForkCopy(_ state: inout State, _ stamp: Date) -> Bool {
        guard state.suppressingForkCopies else { return false }
        if stamp.timeIntervalSince(state.forkCopyAnchor) < forkCopyMaxGap {
            state.forkCopyAnchor = stamp
            return true
        }
        state.suppressingForkCopies = false
        state.lastSignature = nil
        return false
    }

    private static func isForked(_ payload: [String: Any]) -> Bool {
        if payload["forked_from_id"] is String { return true }
        let source = payload["source"] as? [String: Any]
        let spawn = (source?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
        return spawn?["parent_thread_id"] is String
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

    /// Per-day, per-model totals from the last export, grouped by the calendar's local days.
    public func dailyUsage(calendar: Calendar = .current) -> [CodexDailyUsage] {
        var totals: [String: (day: Date, model: String, input: Int, output: Int)] = [:]
        for event in cache.values.flatMap(\.events) {
            let day = calendar.startOfDay(for: event.timestamp)
            let key = "\(day.timeIntervalSince1970)|\(event.model)"
            var entry = totals[key] ?? (day, event.model, 0, 0)
            entry.input += event.inputTokens
            entry.output += event.outputTokens
            totals[key] = entry
        }
        return totals.values
            .map { CodexDailyUsage(dayStart: $0.day, model: $0.model, inputTokens: $0.input, outputTokens: $0.output) }
            .sorted { ($0.dayStart, $0.model) < ($1.dayStart, $1.model) }
    }

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
