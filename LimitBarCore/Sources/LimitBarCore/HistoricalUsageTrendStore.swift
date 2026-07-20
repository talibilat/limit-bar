import Foundation
import SQLite3

public enum HistoricalUsageTrendStoreError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case decodeFailed(String)
    case unsupportedSchemaVersion(Int)
    case invalidSchemaFingerprint(Int)
}

public final class HistoricalUsageTrendStore {
    public static let schemaVersion = 4
    public static let observationColumnNames: Set<String> = [
        "observation_id", "supersedes_observation_id", "revision", "provider",
        "source_kind", "source_identifier", "coverage_kind", "coverage_model",
        "period_kind", "period_start", "period_end", "window_basis",
        "aggregation_version", "time_zone_identifier", "recorded_at", "finality",
        "input_tokens", "output_tokens", "provider_cost_amount", "provider_cost_currency",
        "calculated_cost_amount", "calculated_cost_currency", "pricing_revision",
        "pricing_effective_at"
    ]
    public static let sixHourAggregateColumnNames: Set<String> = [
        "aggregate_id", "supersedes_aggregate_id", "revision", "provider",
        "source_kind", "source_identifier", "coverage_kind", "coverage_model",
        "period_start", "period_end", "aggregation_version", "input_tokens",
        "output_tokens", "source_revision", "recorded_at"
    ]

    private var database: OpaquePointer?

    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw HistoricalUsageTrendStoreError.openFailed(Self.message(from: database))
        }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        do {
            try configureSchema()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public static func inMemory() throws -> HistoricalUsageTrendStore {
        try HistoricalUsageTrendStore(path: ":memory:")
    }

    public static func applicationSupportStore(fileManager: FileManager = .default) throws -> HistoricalUsageTrendStore {
        try HistoricalUsageTrendStore(path: LimitBarFileLocations.production(fileManager: fileManager).historicalUsageDatabase.path)
    }

    @discardableResult
    public func record(
        _ samples: [HistoricalUsageTrendSample],
        observedScopes: Set<HistoricalUsageObservedScope> = [],
        now: Date = Date()
    ) throws -> [HistoricalUsageTrendObservation] {
        try transaction {
            try finalizeEndedObservations(now: now, incomingSamples: samples)
            var observations: [HistoricalUsageTrendObservation] = []
            for sample in samples {
                let lifecycle: HistoricalUsageObservationLifecycle = now >= sample.period.window.end ? .final : .provisional
                if let current = try currentObservation(matching: sample),
                   current.sample == sample,
                   current.lifecycle == lifecycle {
                    observations.append(current)
                    continue
                }
                let previous = try currentObservation(matching: sample)
                let observation = HistoricalUsageTrendObservation(
                    id: UUID(),
                    revision: (previous?.revision ?? 0) + 1,
                    supersedesID: previous?.id,
                    lifecycle: lifecycle,
                    recordedAt: now,
                    sample: sample
                )
                try insert(observation)
                observations.append(observation)
            }
            try recordMissingSamplesAsZero(samples, observedScopes: observedScopes, now: now)
            _ = try pruneWithoutTransaction(now: now)
            return observations
        }
    }

    public func buckets(
        for periods: [HistoricalUsageTrendPeriod],
        provider: ProviderKind? = nil
    ) throws -> [HistoricalUsageTrendBucket] {
        try periods.map { period in
            let observations = try observations(for: period, provider: provider, includeSuperseded: false)
            return HistoricalUsageTrendBucket(
                period: period,
                value: observations.isEmpty ? .gap : .observed(observations)
            )
        }
    }

    public func buckets(
        from start: Date,
        through end: Date,
        provider: ProviderKind? = nil,
        window: TimeWindow? = nil
    ) throws -> [HistoricalUsageTrendBucket] {
        try buckets(for: periods(from: start, through: end, provider: provider, window: window), provider: provider)
    }

    public func periods(
        from start: Date,
        through end: Date,
        provider: ProviderKind? = nil,
        window: TimeWindow? = nil
    ) throws -> [HistoricalUsageTrendPeriod] {
        var sql = """
        SELECT DISTINCT period_kind, period_start, period_end, window_basis,
                        aggregation_version, time_zone_identifier
        FROM historical_usage_observations
        WHERE period_start >= ? AND period_end <= ?
        """
        if provider != nil { sql += " AND provider = ?" }
        if window != nil { sql += " AND period_kind = ?" }
        sql += " ORDER BY period_start, period_end, time_zone_identifier, window_basis;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(start, at: 1, in: statement)
        bind(end, at: 2, in: statement)
        var index: Int32 = 3
        if let provider { bind(provider.rawValue, at: index, in: statement); index += 1 }
        if let window { bind(window.rawValue, at: index, in: statement) }

        var result: [HistoricalUsageTrendPeriod] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw executionError() }
            result.append(try decodePeriod(statement, offset: 0))
        }
    }

    public func revisions(
        for period: HistoricalUsageTrendPeriod,
        provider: ProviderKind? = nil
    ) throws -> [HistoricalUsageTrendObservation] {
        try observations(for: period, provider: provider, includeSuperseded: true)
    }

    @discardableResult
    public func recordSixHourAggregates(
        _ aggregates: [HistoricalSixHourUsageAggregate],
        sourceRevision: String,
        now: Date = Date()
    ) throws -> [HistoricalSixHourUsageAggregateObservation] {
        try transaction {
            var recorded: [HistoricalSixHourUsageAggregateObservation] = []
            for aggregate in aggregates {
                let previous = try currentSixHourAggregate(matching: aggregate)
                if let previous, previous.aggregate == aggregate {
                    recorded.append(previous)
                    continue
                }
                let observation = HistoricalSixHourUsageAggregateObservation(
                    id: UUID(),
                    revision: (previous?.revision ?? 0) + 1,
                    supersedesID: previous?.id,
                    sourceRevision: sourceRevision,
                    recordedAt: now,
                    aggregate: aggregate
                )
                try insert(observation)
                recorded.append(observation)
            }
            _ = try pruneWithoutTransaction(now: now)
            return recorded
        }
    }

    public func sixHourAggregates(
        from start: Date,
        through end: Date,
        source: UsageMetricSource? = nil
    ) throws -> [HistoricalSixHourUsageAggregateObservation] {
        var sql = Self.sixHourAggregateSelect + " WHERE a.period_start >= ? AND a.period_end <= ? AND NOT EXISTS (SELECT 1 FROM historical_six_hour_aggregates n WHERE n.supersedes_aggregate_id = a.aggregate_id)"
        if source != nil { sql += " AND a.source_kind = ? AND IFNULL(a.source_identifier, '') = ?" }
        sql += " ORDER BY a.period_start, a.provider, a.source_kind, a.source_identifier, a.coverage_model;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(start, at: 1, in: statement)
        bind(end, at: 2, in: statement)
        if let source {
            let encoded = encode(source)
            bind(encoded.kind, at: 3, in: statement)
            bind(encoded.identifier ?? "", at: 4, in: statement)
        }
        return try decodeSixHourAggregates(statement)
    }

    public func sixHourRevisions(
        matching aggregate: HistoricalSixHourUsageAggregate
    ) throws -> [HistoricalSixHourUsageAggregateObservation] {
        let source = encode(aggregate.source)
        let sql = Self.sixHourAggregateSelect + " WHERE a.provider = ? AND a.source_kind = ? AND IFNULL(a.source_identifier, '') = ? AND a.coverage_model = ? AND a.period_start = ? AND a.period_end = ? AND a.aggregation_version = ? ORDER BY a.revision;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(aggregate.provider.rawValue, at: 1, in: statement)
        bind(source.kind, at: 2, in: statement)
        bind(source.identifier ?? "", at: 3, in: statement)
        bind(aggregate.model, at: 4, in: statement)
        bind(aggregate.window.start, at: 5, in: statement)
        bind(aggregate.window.end, at: 6, in: statement)
        sqlite3_bind_int64(statement, 7, Int64(aggregate.window.aggregationVersion))
        return try decodeSixHourAggregates(statement)
    }

    public func retention() throws -> HistoricalUsageRetention {
        let statement = try prepare("SELECT value FROM historical_usage_settings WHERE key = 'retention_days';")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let retention = HistoricalUsageRetention(rawValue: Int(sqlite3_column_int(statement, 0))) else {
            throw HistoricalUsageTrendStoreError.decodeFailed("Invalid retention setting")
        }
        return retention
    }

    @discardableResult
    public func setRetention(_ retention: HistoricalUsageRetention, now: Date = Date()) throws -> Int {
        try transaction {
            let statement = try prepare("UPDATE historical_usage_settings SET value = ? WHERE key = 'retention_days';")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(retention.rawValue))
            try stepDone(statement)
            return try pruneWithoutTransaction(now: now)
        }
    }

    @discardableResult
    public func prune(now: Date = Date()) throws -> Int {
        try transaction { try pruneWithoutTransaction(now: now) }
    }

    @discardableResult
    public func deleteAll() throws -> Int {
        let deleted = try transaction {
            try execute("PRAGMA secure_delete = ON;")
            try execute("DELETE FROM historical_usage_observations;")
            let observations = Int(sqlite3_changes(database))
            try execute("DELETE FROM historical_six_hour_aggregates;")
            return observations + Int(sqlite3_changes(database))
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try execute("VACUUM;")
        return deleted
    }

    @discardableResult
    public func deleteCustomSources(excluding sourceIDs: Set<UUID>) throws -> Int {
        try transaction {
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
            let predicate = sourceIDs.isEmpty ? "" : " AND source_identifier NOT IN (\(placeholders))"
            var deleted = 0
            for table in ["historical_usage_observations", "historical_six_hour_aggregates"] {
                let statement = try prepare("DELETE FROM \(table) WHERE source_kind = 'custom'\(predicate);")
                defer { sqlite3_finalize(statement) }
                for (index, sourceID) in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                    bind(sourceID.uuidString, at: Int32(index + 1), in: statement)
                }
                try stepDone(statement)
                deleted += Int(sqlite3_changes(database))
            }
            return deleted
        }
    }

    func schemaColumnNames() throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(historical_usage_observations);")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { columns.insert(requiredString(statement, index: 1)) }
        return columns
    }

    func sixHourSchemaColumnNames() throws -> Set<String> {
        try columnNames(in: "historical_six_hour_aggregates")
    }

    private func currentObservation(matching sample: HistoricalUsageTrendSample) throws -> HistoricalUsageTrendObservation? {
        let rows = try observations(for: sample.period, provider: sample.provider, includeSuperseded: false)
        return rows.first { identity(of: $0.sample) == identity(of: sample) }
    }

    private func finalizeEndedObservations(
        now: Date,
        incomingSamples: [HistoricalUsageTrendSample]
    ) throws {
        let incomingIdentities = Set(incomingSamples.map { identity(of: $0) })
        let sql = Self.observationSelect + " WHERE o.finality = 'provisional' AND o.period_end <= ? AND NOT EXISTS (SELECT 1 FROM historical_usage_observations n WHERE n.supersedes_observation_id = o.observation_id);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(now, at: 1, in: statement)
        var ended: [HistoricalUsageTrendObservation] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw executionError() }
            ended.append(try decodeObservation(statement))
        }
        for previous in ended where !incomingIdentities.contains(identity(of: previous.sample)) {
            try insert(HistoricalUsageTrendObservation(
                id: UUID(),
                revision: previous.revision + 1,
                supersedesID: previous.id,
                lifecycle: .final,
                recordedAt: now,
                sample: previous.sample
            ))
        }
    }

    private func recordMissingSamplesAsZero(
        _ samples: [HistoricalUsageTrendSample],
        observedScopes: Set<HistoricalUsageObservedScope>,
        now: Date
    ) throws {
        let representedScopes = Set(samples.map {
            HistoricalUsageObservedScope(provider: $0.provider, source: $0.source, period: $0.period)
        }).union(observedScopes)
        let incoming = Set(samples.map { identity(of: $0) })
        for scope in representedScopes {
            let current = try observations(for: scope.period, provider: scope.provider, includeSuperseded: false)
                .filter { $0.sample.source == scope.source }
            for previous in current where !incoming.contains(identity(of: previous.sample)) {
                let zero = try HistoricalUsageTrendSample(
                    provider: previous.sample.provider,
                    source: previous.sample.source,
                    coverage: previous.sample.coverage,
                    period: previous.sample.period,
                    tokenUsage: TokenUsage(inputTokens: 0, outputTokens: 0)
                )
                try insert(HistoricalUsageTrendObservation(
                    id: UUID(),
                    revision: previous.revision + 1,
                    supersedesID: previous.id,
                    lifecycle: now >= zero.period.window.end ? .final : .provisional,
                    recordedAt: now,
                    sample: zero
                ))
            }
        }
    }

    private func insert(_ observation: HistoricalUsageTrendObservation) throws {
        let sql = """
        INSERT INTO historical_usage_observations (
            observation_id, supersedes_observation_id, revision, provider,
            source_kind, source_identifier, coverage_kind, coverage_model,
            period_kind, period_start, period_end, window_basis, aggregation_version,
            time_zone_identifier, recorded_at, finality, input_tokens, output_tokens,
            provider_cost_amount, provider_cost_currency, calculated_cost_amount,
            calculated_cost_currency, pricing_revision, pricing_effective_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let sample = observation.sample
        let source = encode(sample.source)
        let coverage = encode(sample.coverage)
        bind(observation.id.uuidString, at: 1, in: statement)
        bind(observation.supersedesID?.uuidString, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, Int64(observation.revision))
        bind(sample.provider.rawValue, at: 4, in: statement)
        bind(source.kind, at: 5, in: statement)
        bind(source.identifier, at: 6, in: statement)
        bind(coverage.kind, at: 7, in: statement)
        bind(coverage.model, at: 8, in: statement)
        bind(sample.period.window.timeWindow.rawValue, at: 9, in: statement)
        bind(sample.period.window.start, at: 10, in: statement)
        bind(sample.period.window.end, at: 11, in: statement)
        bind(sample.period.window.basis.rawValue, at: 12, in: statement)
        sqlite3_bind_int64(statement, 13, Int64(sample.period.window.aggregationVersion))
        bind(sample.period.timeZoneIdentifier, at: 14, in: statement)
        bind(observation.recordedAt, at: 15, in: statement)
        bind(observation.lifecycle.rawValue, at: 16, in: statement)
        sqlite3_bind_int64(statement, 17, Int64(sample.tokenUsage.inputTokens))
        sqlite3_bind_int64(statement, 18, Int64(sample.tokenUsage.outputTokens))
        bind(decimalText(sample.providerReportedCost?.amount), at: 19, in: statement)
        bind(sample.providerReportedCost?.currencyCode, at: 20, in: statement)
        bind(decimalText(sample.calculatedCost?.cost.amount), at: 21, in: statement)
        bind(sample.calculatedCost?.cost.currencyCode, at: 22, in: statement)
        bind(sample.calculatedCost?.pricingRevision, at: 23, in: statement)
        bind(sample.calculatedCost?.pricingEffectiveAt, at: 24, in: statement)
        try stepDone(statement)
    }

    private func observations(
        for period: HistoricalUsageTrendPeriod,
        provider: ProviderKind?,
        includeSuperseded: Bool
    ) throws -> [HistoricalUsageTrendObservation] {
        var sql = Self.observationSelect + " WHERE o.period_kind = ? AND o.period_start = ? AND o.period_end = ? AND o.window_basis = ? AND o.aggregation_version = ? AND o.time_zone_identifier = ?"
        if provider != nil { sql += " AND o.provider = ?" }
        if !includeSuperseded {
            sql += " AND NOT EXISTS (SELECT 1 FROM historical_usage_observations n WHERE n.supersedes_observation_id = o.observation_id)"
        }
        sql += " ORDER BY o.provider, o.coverage_kind, o.coverage_model, o.source_kind, o.source_identifier, o.revision;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(period.window.timeWindow.rawValue, at: 1, in: statement)
        bind(period.window.start, at: 2, in: statement)
        bind(period.window.end, at: 3, in: statement)
        bind(period.window.basis.rawValue, at: 4, in: statement)
        sqlite3_bind_int64(statement, 5, Int64(period.window.aggregationVersion))
        bind(period.timeZoneIdentifier, at: 6, in: statement)
        if let provider { bind(provider.rawValue, at: 7, in: statement) }

        var result: [HistoricalUsageTrendObservation] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw executionError() }
            result.append(try decodeObservation(statement))
        }
    }

    private static let observationSelect = """
    SELECT o.observation_id, o.supersedes_observation_id, o.revision, o.provider,
           o.source_kind, o.source_identifier, o.coverage_kind, o.coverage_model,
           o.period_kind, o.period_start, o.period_end, o.window_basis,
           o.aggregation_version, o.time_zone_identifier, o.recorded_at, o.finality,
           o.input_tokens, o.output_tokens, o.provider_cost_amount, o.provider_cost_currency,
           o.calculated_cost_amount, o.calculated_cost_currency, o.pricing_revision,
           o.pricing_effective_at,
           EXISTS (SELECT 1 FROM historical_usage_observations n WHERE n.supersedes_observation_id = o.observation_id)
    FROM historical_usage_observations o
    """

    private func decodeObservation(_ statement: OpaquePointer?) throws -> HistoricalUsageTrendObservation {
        guard let id = UUID(uuidString: requiredString(statement, index: 0)),
              let provider = ProviderKind(rawValue: requiredString(statement, index: 3)) else {
            throw HistoricalUsageTrendStoreError.decodeFailed("Invalid observation identity")
        }
        do {
            let period = try decodePeriod(statement, offset: 8)
            let sample = try HistoricalUsageTrendSample(
                provider: provider,
                source: try decodeSource(kind: requiredString(statement, index: 4), identifier: stringColumn(statement, index: 5)),
                coverage: try decodeCoverage(kind: requiredString(statement, index: 6), model: stringColumn(statement, index: 7)),
                period: period,
                tokenUsage: TokenUsage(
                    inputTokens: Int(sqlite3_column_int64(statement, 16)),
                    outputTokens: Int(sqlite3_column_int64(statement, 17))
                ),
                providerReportedCost: try decodeCost(statement, amount: 18, currency: 19, source: .providerReported),
                calculatedCost: try decodeCalculatedCost(statement)
            )
            guard let storedFinality = HistoricalUsageObservationLifecycle(rawValue: requiredString(statement, index: 15)),
                  storedFinality == .provisional || storedFinality == .final else {
                throw HistoricalUsageTrendStoreError.decodeFailed("Invalid observation finality")
            }
            return HistoricalUsageTrendObservation(
                id: id,
                revision: Int(sqlite3_column_int64(statement, 2)),
                supersedesID: stringColumn(statement, index: 1).flatMap(UUID.init(uuidString:)),
                lifecycle: sqlite3_column_int(statement, 24) == 1 ? .superseded : storedFinality,
                recordedAt: dateColumn(statement, index: 14),
                sample: sample
            )
        } catch let error as HistoricalUsageTrendStoreError {
            throw error
        } catch {
            throw HistoricalUsageTrendStoreError.decodeFailed("Invalid historical observation")
        }
    }

    private func decodePeriod(_ statement: OpaquePointer?, offset: Int32) throws -> HistoricalUsageTrendPeriod {
        guard let kind = TimeWindow(rawValue: requiredString(statement, index: offset)),
              let basis = UsageWindowBasis(rawValue: requiredString(statement, index: offset + 3)) else {
            throw HistoricalUsageTrendStoreError.decodeFailed("Invalid period")
        }
        let window = try ExactUsageWindow(
            timeWindow: kind,
            start: dateColumn(statement, index: offset + 1),
            end: dateColumn(statement, index: offset + 2),
            basis: basis,
            aggregationVersion: Int(sqlite3_column_int64(statement, offset + 4))
        )
        return try HistoricalUsageTrendPeriod(window: window, timeZoneIdentifier: requiredString(statement, index: offset + 5))
    }

    private func decodeCalculatedCost(_ statement: OpaquePointer?) throws -> HistoricalUsageCalculatedCost? {
        let cost = try decodeCost(statement, amount: 20, currency: 21, source: .calculatedEstimate)
        let revision = stringColumn(statement, index: 22)
        let effectiveAt = nullableDateColumn(statement, index: 23)
        if cost == nil, revision == nil, effectiveAt == nil { return nil }
        guard let cost, let revision, let effectiveAt else {
            throw HistoricalUsageTrendStoreError.decodeFailed("Incomplete calculated cost")
        }
        return try HistoricalUsageCalculatedCost(cost: cost, pricingRevision: revision, pricingEffectiveAt: effectiveAt)
    }

    private func decodeCost(_ statement: OpaquePointer?, amount: Int32, currency: Int32, source: CostSource) throws -> Cost? {
        let amountText = stringColumn(statement, index: amount)
        let currencyCode = stringColumn(statement, index: currency)
        if amountText == nil, currencyCode == nil { return nil }
        guard let amountText, let amount = Decimal(string: amountText), let currencyCode else {
            throw HistoricalUsageTrendStoreError.decodeFailed("Invalid cost")
        }
        return Cost(amount: amount, currencyCode: currencyCode, source: source)
    }

    private func currentSixHourAggregate(
        matching aggregate: HistoricalSixHourUsageAggregate
    ) throws -> HistoricalSixHourUsageAggregateObservation? {
        try sixHourRevisions(matching: aggregate).last
    }

    private func insert(_ observation: HistoricalSixHourUsageAggregateObservation) throws {
        let sql = """
        INSERT INTO historical_six_hour_aggregates (
            aggregate_id, supersedes_aggregate_id, revision, provider, source_kind,
            source_identifier, coverage_kind, coverage_model, period_start, period_end,
            aggregation_version, input_tokens, output_tokens, source_revision, recorded_at
        ) VALUES (?, ?, ?, ?, ?, ?, 'model', ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let aggregate = observation.aggregate
        let source = encode(aggregate.source)
        bind(observation.id.uuidString, at: 1, in: statement)
        bind(observation.supersedesID?.uuidString, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, Int64(observation.revision))
        bind(aggregate.provider.rawValue, at: 4, in: statement)
        bind(source.kind, at: 5, in: statement)
        bind(source.identifier, at: 6, in: statement)
        bind(aggregate.model, at: 7, in: statement)
        bind(aggregate.window.start, at: 8, in: statement)
        bind(aggregate.window.end, at: 9, in: statement)
        sqlite3_bind_int64(statement, 10, Int64(aggregate.window.aggregationVersion))
        sqlite3_bind_int64(statement, 11, Int64(aggregate.tokenUsage.inputTokens))
        sqlite3_bind_int64(statement, 12, Int64(aggregate.tokenUsage.outputTokens))
        bind(observation.sourceRevision, at: 13, in: statement)
        bind(observation.recordedAt, at: 14, in: statement)
        try stepDone(statement)
    }

    private static let sixHourAggregateSelect = """
    SELECT a.aggregate_id, a.supersedes_aggregate_id, a.revision, a.provider,
           a.source_kind, a.source_identifier, a.coverage_kind, a.coverage_model,
           a.period_start, a.period_end, a.aggregation_version, a.input_tokens,
           a.output_tokens, a.source_revision, a.recorded_at
    FROM historical_six_hour_aggregates a
    """

    private func decodeSixHourAggregates(
        _ statement: OpaquePointer?
    ) throws -> [HistoricalSixHourUsageAggregateObservation] {
        var result: [HistoricalSixHourUsageAggregateObservation] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW,
                  let id = UUID(uuidString: requiredString(statement, index: 0)),
                  let provider = ProviderKind(rawValue: requiredString(statement, index: 3)),
                  requiredString(statement, index: 6) == "model" else {
                throw HistoricalUsageTrendStoreError.decodeFailed("Invalid six-hour aggregate identity")
            }
            do {
                let aggregate = try HistoricalSixHourUsageAggregate(
                    provider: provider,
                    source: try decodeSource(
                        kind: requiredString(statement, index: 4),
                        identifier: stringColumn(statement, index: 5)
                    ),
                    model: requiredString(statement, index: 7),
                    window: try HistoricalSixHourUsageWindow(
                        start: dateColumn(statement, index: 8),
                        end: dateColumn(statement, index: 9),
                        aggregationVersion: Int(sqlite3_column_int64(statement, 10))
                    ),
                    tokenUsage: TokenUsage(
                        inputTokens: Int(sqlite3_column_int64(statement, 11)),
                        outputTokens: Int(sqlite3_column_int64(statement, 12))
                    )
                )
                result.append(HistoricalSixHourUsageAggregateObservation(
                    id: id,
                    revision: Int(sqlite3_column_int64(statement, 2)),
                    supersedesID: stringColumn(statement, index: 1).flatMap(UUID.init(uuidString:)),
                    sourceRevision: requiredString(statement, index: 13),
                    recordedAt: dateColumn(statement, index: 14),
                    aggregate: aggregate
                ))
            } catch let error as HistoricalUsageTrendStoreError {
                throw error
            } catch {
                throw HistoricalUsageTrendStoreError.decodeFailed("Invalid six-hour aggregate")
            }
        }
    }

    private func pruneWithoutTransaction(now: Date) throws -> Int {
        let retention = try retention()
        let periods = try periods(from: .distantPast, through: now)
        var expired: [HistoricalUsageTrendPeriod] = []
        for period in periods {
            guard let timeZone = TimeZone(identifier: period.timeZoneIdentifier) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let today = calendar.startOfDay(for: now)
            guard let cutoff = calendar.date(byAdding: .day, value: -retention.rawValue, to: today) else { continue }
            if period.window.end <= cutoff { expired.append(period) }
        }
        var deleted = 0
        for period in expired {
            let statement = try prepare("DELETE FROM historical_usage_observations WHERE period_kind = ? AND period_start = ? AND period_end = ? AND window_basis = ? AND aggregation_version = ? AND time_zone_identifier = ?;")
            defer { sqlite3_finalize(statement) }
            bind(period.window.timeWindow.rawValue, at: 1, in: statement)
            bind(period.window.start, at: 2, in: statement)
            bind(period.window.end, at: 3, in: statement)
            bind(period.window.basis.rawValue, at: 4, in: statement)
            sqlite3_bind_int64(statement, 5, Int64(period.window.aggregationVersion))
            bind(period.timeZoneIdentifier, at: 6, in: statement)
            try stepDone(statement)
            deleted += Int(sqlite3_changes(database))
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let today = utc.startOfDay(for: now)
        if let cutoff = utc.date(byAdding: .day, value: -retention.rawValue, to: today) {
            let statement = try prepare("DELETE FROM historical_six_hour_aggregates WHERE period_end <= ?;")
            defer { sqlite3_finalize(statement) }
            bind(cutoff, at: 1, in: statement)
            try stepDone(statement)
            deleted += Int(sqlite3_changes(database))
        }
        return deleted
    }

    private func configureSchema() throws {
        let version = try userVersion()
        switch version {
        case 0:
            guard try schemaObjects().isEmpty else {
                throw HistoricalUsageTrendStoreError.invalidSchemaFingerprint(version)
            }
            try transaction {
                try createLegacySchema()
                try createSixHourSchema()
                try execute("PRAGMA user_version = \(Self.schemaVersion);")
            }
        case 3:
            guard try hasKnownLegacySchema() else {
                throw HistoricalUsageTrendStoreError.invalidSchemaFingerprint(version)
            }
            try transaction {
                try createSixHourSchema()
                try execute("PRAGMA user_version = \(Self.schemaVersion);")
            }
        case Self.schemaVersion:
            guard try hasKnownLegacySchema(),
                  try sixHourSchemaColumnNames() == Self.sixHourAggregateColumnNames,
                  try schemaObjects() == Self.currentSchemaObjects else {
                throw HistoricalUsageTrendStoreError.invalidSchemaFingerprint(version)
            }
        default:
            throw HistoricalUsageTrendStoreError.unsupportedSchemaVersion(version)
        }
    }

    private func createLegacySchema() throws {
        try execute(Self.legacySchemaSQL)
    }

    private func createSixHourSchema() throws {
        try execute(Self.sixHourSchemaSQL)
    }

    private func hasKnownLegacySchema() throws -> Bool {
        guard try schemaColumnNames() == Self.observationColumnNames,
              try columnNames(in: "historical_usage_settings") == ["key", "value"] else {
            return false
        }
        let objects = try schemaObjects()
        let expected = objects.contains("historical_six_hour_aggregates")
            ? Self.currentSchemaObjects
            : Self.legacySchemaObjects
        let expectedSQL = objects.contains("historical_six_hour_aggregates")
            ? Self.legacySchemaSQL + Self.sixHourSchemaSQL
            : Self.legacySchemaSQL
        guard objects == expected,
              try schemaDefinitions() == Self.canonicalSchemaDefinitions(for: expectedSQL) else {
            return false
        }
        let statement = try prepare("SELECT COUNT(*), MIN(value), MAX(value) FROM historical_usage_settings WHERE key = 'retention_days' AND value IN (30, 90, 365, 730);")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
            && sqlite3_column_int(statement, 0) == 1
            && sqlite3_column_int(statement, 1) == sqlite3_column_int(statement, 2)
    }

    private func columnNames(in table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { columns.insert(requiredString(statement, index: 1)) }
        return columns
    }

    private func schemaObjects() throws -> Set<String> {
        let statement = try prepare("SELECT name FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(requiredString(statement, index: 0)) }
        return names
    }

    private func schemaDefinitions() throws -> [String: String] {
        let statement = try prepare("SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%';")
        defer { sqlite3_finalize(statement) }
        var definitions: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            definitions[requiredString(statement, index: 0)] = Self.normalizeSchemaSQL(requiredString(statement, index: 1))
        }
        return definitions
    }

    private static func canonicalSchemaDefinitions(for sql: String) throws -> [String: String] {
        var canonical: OpaquePointer?
        guard sqlite3_open(":memory:", &canonical) == SQLITE_OK else {
            sqlite3_close(canonical)
            throw HistoricalUsageTrendStoreError.openFailed("Unable to build schema fingerprint")
        }
        defer { sqlite3_close(canonical) }
        guard sqlite3_exec(canonical, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoricalUsageTrendStoreError.executeFailed("Unable to build schema fingerprint")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(canonical, "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%';", -1, &statement, nil) == SQLITE_OK else {
            throw HistoricalUsageTrendStoreError.prepareFailed("Unable to build schema fingerprint")
        }
        defer { sqlite3_finalize(statement) }
        var definitions: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 0).map(String.init(cString:)) ?? ""
            let definition = sqlite3_column_text(statement, 1).map(String.init(cString:)) ?? ""
            definitions[name] = normalizeSchemaSQL(definition)
        }
        return definitions
    }

    private static func normalizeSchemaSQL(_ sql: String) -> String {
        sql.filter { !$0.isWhitespace && $0 != ";" }
    }

    private static let legacySchemaObjects: Set<String> = [
        "historical_usage_observations", "historical_usage_revision",
        "historical_usage_one_correction", "historical_usage_period",
        "historical_usage_settings"
    ]
    private static let currentSchemaObjects = legacySchemaObjects.union([
        "historical_six_hour_aggregates", "historical_six_hour_revision",
        "historical_six_hour_one_correction", "historical_six_hour_period"
    ])

    private static let legacySchemaSQL = """
    CREATE TABLE historical_usage_observations (
        observation_id TEXT PRIMARY KEY,
        supersedes_observation_id TEXT REFERENCES historical_usage_observations(observation_id),
        revision INTEGER NOT NULL CHECK (revision > 0),
        provider TEXT NOT NULL CHECK (provider IN ('anthropic', 'azureOpenAI', 'openAI', 'custom')),
        source_kind TEXT NOT NULL CHECK (source_kind IN ('providerAPI', 'builtInLocalLog', 'custom')),
        source_identifier TEXT,
        coverage_kind TEXT NOT NULL CHECK (coverage_kind IN ('providerTotal', 'model')),
        coverage_model TEXT,
        period_kind TEXT NOT NULL CHECK (period_kind IN ('today', 'currentWeek')),
        period_start INTEGER NOT NULL,
        period_end INTEGER NOT NULL CHECK (period_end > period_start),
        window_basis TEXT NOT NULL CHECK (window_basis IN ('localCalendar', 'utcBilling')),
        aggregation_version INTEGER NOT NULL CHECK (aggregation_version > 0),
        time_zone_identifier TEXT NOT NULL,
        recorded_at INTEGER NOT NULL,
        finality TEXT NOT NULL CHECK (finality IN ('provisional', 'final')),
        input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
        output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
        provider_cost_amount TEXT,
        provider_cost_currency TEXT,
        calculated_cost_amount TEXT,
        calculated_cost_currency TEXT,
        pricing_revision TEXT,
        pricing_effective_at INTEGER,
        CHECK ((source_kind = 'custom') = (source_identifier IS NOT NULL)),
        CHECK ((coverage_kind = 'model') = (coverage_model IS NOT NULL)),
        CHECK ((provider_cost_amount IS NULL) = (provider_cost_currency IS NULL)),
        CHECK ((calculated_cost_amount IS NULL) = (calculated_cost_currency IS NULL)),
        CHECK ((calculated_cost_amount IS NULL) = (pricing_revision IS NULL)),
        CHECK ((calculated_cost_amount IS NULL) = (pricing_effective_at IS NULL)),
        CHECK (window_basis != 'utcBilling' OR time_zone_identifier = 'UTC')
    );
    CREATE UNIQUE INDEX historical_usage_revision ON historical_usage_observations (
        provider, source_kind, IFNULL(source_identifier, ''), coverage_kind,
        IFNULL(coverage_model, ''), period_kind, period_start, period_end,
        window_basis, aggregation_version, time_zone_identifier, revision
    );
    CREATE UNIQUE INDEX historical_usage_one_correction
        ON historical_usage_observations (supersedes_observation_id)
        WHERE supersedes_observation_id IS NOT NULL;
    CREATE INDEX historical_usage_period
        ON historical_usage_observations (period_start, period_end, provider, period_kind);
    CREATE TABLE historical_usage_settings (
        key TEXT PRIMARY KEY CHECK (key = 'retention_days'),
        value INTEGER NOT NULL CHECK (value IN (30, 90, 365, 730))
    );
    INSERT INTO historical_usage_settings (key, value) VALUES ('retention_days', 365);
    """

    private static let sixHourSchemaSQL = """
    CREATE TABLE historical_six_hour_aggregates (
        aggregate_id TEXT PRIMARY KEY,
        supersedes_aggregate_id TEXT REFERENCES historical_six_hour_aggregates(aggregate_id),
        revision INTEGER NOT NULL CHECK (revision > 0),
        provider TEXT NOT NULL CHECK (provider IN ('anthropic', 'azureOpenAI', 'openAI', 'custom')),
        source_kind TEXT NOT NULL CHECK (source_kind IN ('builtInLocalLog', 'custom')),
        source_identifier TEXT,
        coverage_kind TEXT NOT NULL CHECK (coverage_kind = 'model'),
        coverage_model TEXT NOT NULL CHECK (length(coverage_model) > 0),
        period_start INTEGER NOT NULL CHECK (period_start % 21600 = 0),
        period_end INTEGER NOT NULL CHECK (period_end = period_start + 21600),
        aggregation_version INTEGER NOT NULL CHECK (aggregation_version > 0),
        input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
        output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
        source_revision TEXT NOT NULL CHECK (length(source_revision) > 0),
        recorded_at INTEGER NOT NULL,
        CHECK ((source_kind = 'custom') = (source_identifier IS NOT NULL)),
        CHECK ((provider = 'custom') = (source_kind = 'custom'))
    );
    CREATE UNIQUE INDEX historical_six_hour_revision ON historical_six_hour_aggregates (
        provider, source_kind, IFNULL(source_identifier, ''), coverage_kind,
        coverage_model, period_start, period_end, aggregation_version, revision
    );
    CREATE UNIQUE INDEX historical_six_hour_one_correction
        ON historical_six_hour_aggregates (supersedes_aggregate_id)
        WHERE supersedes_aggregate_id IS NOT NULL;
    CREATE INDEX historical_six_hour_period
        ON historical_six_hour_aggregates (period_start, period_end, provider, source_kind);
    """

    private func identity(of sample: HistoricalUsageTrendSample) -> String {
        let source = encode(sample.source)
        let coverage = encode(sample.coverage)
        return [
            sample.provider.rawValue, source.kind, source.identifier ?? "", coverage.kind,
            coverage.model ?? "", sample.period.window.timeWindow.rawValue,
            String(Int64(sample.period.window.start.timeIntervalSince1970)),
            String(Int64(sample.period.window.end.timeIntervalSince1970)),
            sample.period.window.basis.rawValue, String(sample.period.window.aggregationVersion),
            sample.period.timeZoneIdentifier
        ].map { "\($0.utf8.count):\($0)" }.joined()
    }

    private func encode(_ source: UsageMetricSource) -> (kind: String, identifier: String?) {
        switch source {
        case .providerAPI: ("providerAPI", nil)
        case .builtInLocalLog: ("builtInLocalLog", nil)
        case let .custom(id): ("custom", id.uuidString)
        }
    }

    private func decodeSource(kind: String, identifier: String?) throws -> UsageMetricSource {
        switch (kind, identifier) {
        case ("providerAPI", nil): return .providerAPI
        case ("builtInLocalLog", nil): return .builtInLocalLog
        case let ("custom", value):
            guard let value, let id = UUID(uuidString: value) else { break }
            return .custom(id)
        default: break
        }
        throw HistoricalUsageTrendStoreError.decodeFailed("Invalid source")
    }

    private func encode(_ coverage: HistoricalUsageCoverageScope) -> (kind: String, model: String?) {
        switch coverage {
        case .providerTotal: ("providerTotal", nil)
        case let .model(model): ("model", model)
        }
    }

    private func decodeCoverage(kind: String, model: String?) throws -> HistoricalUsageCoverageScope {
        switch (kind, model) {
        case ("providerTotal", nil): return .providerTotal
        case let ("model", model?): return .model(model)
        default: throw HistoricalUsageTrendStoreError.decodeFailed("Invalid coverage")
        }
    }

    private func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw executionError() }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try operation()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw executionError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoricalUsageTrendStoreError.prepareFailed(Self.message(from: database))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw executionError() }
    }

    private func bind(_ value: Date, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func bind(_ value: Date?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        bind(value, at: index, in: statement)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        _ = value.utf8CString.withUnsafeBufferPointer { bytes in
            sqlite3_bind_text(statement, index, bytes.baseAddress, Int32(bytes.count - 1), historicalUsageTrendSQLiteTransient)
        }
    }

    private func dateColumn(_ statement: OpaquePointer?, index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func nullableDateColumn(_ statement: OpaquePointer?, index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : dateColumn(statement, index: index)
    }

    private func requiredString(_ statement: OpaquePointer?, index: Int32) -> String {
        stringColumn(statement, index: index) ?? ""
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }

    private func decimalText(_ decimal: Decimal?) -> String? {
        decimal.map { NSDecimalNumber(decimal: $0).stringValue }
    }

    private func executionError() -> HistoricalUsageTrendStoreError {
        .executeFailed(Self.message(from: database))
    }

    private static func message(from database: OpaquePointer?) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "Unknown SQLite error"
    }
}

private let historicalUsageTrendSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
