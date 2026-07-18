import Foundation
import SQLite3

public enum ModelLifecycleInventoryLoaderError: Error, Equatable {
    case openFailed(String)
    case readFailed(String)
    case invalidRetention
}

public struct ModelLifecycleInventorySnapshot: Equatable, Sendable {
    public let retentionDays: Int
    public let models: [RetainedModelUsage]

    public init(retentionDays: Int, models: [RetainedModelUsage]) {
        self.retentionDays = retentionDays
        self.models = models
    }
}

public final class ModelLifecycleInventoryLoader: @unchecked Sendable {
    private struct Key: Hashable {
        let identity: CatalogModelIdentity
        let observedModelID: String
    }

    private struct Candidate {
        let key: Key
        let interval: DateInterval
        let usage: TokenUsage
    }

    private let path: String

    public init(path: String) {
        self.path = path
    }

    public static func production(fileManager: FileManager = .default) throws -> Self {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return Self(path: applicationSupport
            .appendingPathComponent("LimitBar", isDirectory: true)
            .appendingPathComponent("historical-usage-trends.sqlite")
            .path)
    }

    public func load(catalog: ModelLifecycleCatalog, now: Date = Date()) throws -> ModelLifecycleInventorySnapshot {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = Self.message(database)
            sqlite3_close(database)
            throw ModelLifecycleInventoryLoaderError.openFailed(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)

        let retention = try retentionDays(database)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let utcToday = utc.startOfDay(for: now)
        guard let utcCutoff = utc.date(byAdding: .day, value: -retention, to: utcToday) else {
            throw ModelLifecycleInventoryLoaderError.invalidRetention
        }
        let roughCutoff = utcCutoff.addingTimeInterval(-2 * 24 * 60 * 60)
        let daily = try dailyProviderCandidates(database, catalog: catalog, roughCutoff: roughCutoff, now: now, retentionDays: retention)
        let exact = try exactCandidates(database, catalog: catalog, cutoff: utcCutoff, now: now)
        let dailyCoverage = Dictionary(grouping: daily, by: \.key).mapValues { $0.map(\.interval) }

        var totals: [Key: (input: Int, output: Int, start: Date, end: Date)] = [:]
        for candidate in daily {
            add(candidate, to: &totals)
        }
        for candidate in exact {
            guard !(dailyCoverage[candidate.key] ?? []).contains(where: {
                $0.start <= candidate.interval.start && $0.end >= candidate.interval.end
            }) else { continue }
            add(candidate, to: &totals)
        }

        let models = totals.map { key, value in
            RetainedModelUsage(
                identity: key.identity,
                observedModelID: key.observedModelID,
                workloadPeriod: DateInterval(start: value.start, end: value.end),
                tokenUsage: TokenUsage(inputTokens: value.input, outputTokens: value.output)
            )
        }.sorted {
            if $0.identity.product != $1.identity.product { return $0.identity.product.rawValue < $1.identity.product.rawValue }
            if $0.identity.platform != $1.identity.platform { return $0.identity.platform.rawValue < $1.identity.platform.rawValue }
            return $0.observedModelID < $1.observedModelID
        }
        return ModelLifecycleInventorySnapshot(retentionDays: retention, models: models)
    }

    private func retentionDays(_ database: OpaquePointer?) throws -> Int {
        let statement = try prepare(database, "SELECT value FROM historical_usage_settings WHERE key = 'retention_days';")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw readError(database) }
        let value = Int(sqlite3_column_int64(statement, 0))
        guard [30, 90, 365, 730].contains(value) else { throw ModelLifecycleInventoryLoaderError.invalidRetention }
        return value
    }

    private func dailyProviderCandidates(
        _ database: OpaquePointer?,
        catalog: ModelLifecycleCatalog,
        roughCutoff: Date,
        now: Date,
        retentionDays: Int
    ) throws -> [Candidate] {
        let statement = try prepare(database, """
        SELECT o.provider, o.coverage_model, o.period_start, o.period_end,
               o.time_zone_identifier, o.input_tokens, o.output_tokens
        FROM historical_usage_observations o
        WHERE o.source_kind = 'providerAPI'
          AND o.coverage_kind = 'model'
          AND o.period_kind = 'today'
          AND o.period_end > ?
          AND NOT EXISTS (
              SELECT 1 FROM historical_usage_observations n
              WHERE n.supersedes_observation_id = o.observation_id
          )
        ORDER BY o.period_start, o.provider, o.coverage_model;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, roughCutoff.timeIntervalSince1970)
        var values: [Candidate] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { throw readError(database) }
            guard let provider = ProviderKind(rawValue: string(statement, 0)),
                  let product = ProviderProduct(provider: provider),
                  let platform = ModelPlatform(provider: provider),
                  let timeZone = TimeZone(identifier: string(statement, 4)) else { continue }
            let model = string(statement, 1)
            let start = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let end = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now)),
                  end > cutoff, start <= now,
                  let record = ModelCatalogMatcher.match(product: product, platform: platform, modelID: model, in: catalog) else { continue }
            let usage = TokenUsage(
                inputTokens: Int(sqlite3_column_int64(statement, 5)),
                outputTokens: Int(sqlite3_column_int64(statement, 6))
            )
            guard usage.inputTokens >= 0, usage.outputTokens >= 0, usage.totalTokens > 0 else { continue }
            values.append(Candidate(
                key: Key(identity: record.identity, observedModelID: model),
                interval: DateInterval(start: start, end: end),
                usage: usage
            ))
        }
    }

    private func exactCandidates(
        _ database: OpaquePointer?,
        catalog: ModelLifecycleCatalog,
        cutoff: Date,
        now: Date
    ) throws -> [Candidate] {
        guard try tableExists(database, name: "historical_six_hour_aggregates") else { return [] }
        let statement = try prepare(database, """
        SELECT a.provider, a.coverage_model, a.period_start, a.period_end,
               a.input_tokens, a.output_tokens
        FROM historical_six_hour_aggregates a
        WHERE a.coverage_kind = 'model'
          AND a.period_end > ?
          AND a.period_start <= ?
          AND NOT EXISTS (
              SELECT 1 FROM historical_six_hour_aggregates n
              WHERE n.supersedes_aggregate_id = a.aggregate_id
          )
        ORDER BY a.period_start, a.provider, a.coverage_model;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        var values: [Candidate] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { throw readError(database) }
            guard let provider = ProviderKind(rawValue: string(statement, 0)),
                  let product = ProviderProduct(provider: provider),
                  let platform = ModelPlatform(provider: provider) else { continue }
            let model = string(statement, 1)
            guard let record = ModelCatalogMatcher.match(product: product, platform: platform, modelID: model, in: catalog) else { continue }
            let usage = TokenUsage(
                inputTokens: Int(sqlite3_column_int64(statement, 4)),
                outputTokens: Int(sqlite3_column_int64(statement, 5))
            )
            guard usage.inputTokens >= 0, usage.outputTokens >= 0, usage.totalTokens > 0 else { continue }
            values.append(Candidate(
                key: Key(identity: record.identity, observedModelID: model),
                interval: DateInterval(
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                ),
                usage: usage
            ))
        }
    }

    private func tableExists(_ database: OpaquePointer?, name: String) throws -> Bool {
        let statement = try prepare(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;")
        defer { sqlite3_finalize(statement) }
        bind(name, index: 1, statement: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw readError(database) }
        return status == SQLITE_ROW
    }

    private func add(
        _ candidate: Candidate,
        to totals: inout [Key: (input: Int, output: Int, start: Date, end: Date)]
    ) {
        let current = totals[candidate.key] ?? (0, 0, candidate.interval.start, candidate.interval.end)
        let input = current.input.addingReportingOverflow(candidate.usage.inputTokens)
        let output = current.output.addingReportingOverflow(candidate.usage.outputTokens)
        guard !input.overflow, !output.overflow else { return }
        totals[candidate.key] = (
            input.partialValue,
            output.partialValue,
            min(current.start, candidate.interval.start),
            max(current.end, candidate.interval.end)
        )
    }

    private func prepare(_ database: OpaquePointer?, _ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw readError(database) }
        return statement
    }

    private func bind(_ value: String, index: Int32, statement: OpaquePointer?) {
        _ = value.utf8CString.withUnsafeBufferPointer { bytes in
            sqlite3_bind_text(statement, index, bytes.baseAddress, Int32(bytes.count - 1), modelLifecycleSQLiteTransient)
        }
    }

    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }

    private func readError(_ database: OpaquePointer?) -> ModelLifecycleInventoryLoaderError {
        .readFailed(Self.message(database))
    }

    private static func message(_ database: OpaquePointer?) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "Unknown SQLite error"
    }
}

private let modelLifecycleSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
