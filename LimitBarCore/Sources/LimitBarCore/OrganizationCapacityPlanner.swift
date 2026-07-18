import CryptoKit
import Foundation

public enum OrganizationCapacityError: Error, Equatable, Sendable {
    case malformedFile
    case unsupportedSchema
    case administratorReviewRequired
    case unsupportedAggregation
    case unknownField(String)
    case prohibitedField(String)
    case invalidValue(String)
    case partialDay
    case duplicateRecord
    case aliasKeyUnavailable
    case storageUnavailable
    case duplicateImport
    case unknownDatabaseSchema
    case organizationModeDisabled
    case deletionRecoveryRequired
}

public struct OrganizationModeCapabilities: Equatable, Sendable {
    public enum ImportMode: String, Sendable { case manuallySelectedAdministratorReviewedFile }

    public let importMode: ImportMode
    public let allowsOrganizationNetworkRequests: Bool
    public let acceptsOrganizationCredentials: Bool

    public static let validationFirst = Self(
        importMode: .manuallySelectedAdministratorReviewedFile,
        allowsOrganizationNetworkRequests: false,
        acceptsOrganizationCredentials: false
    )
}

public struct OrganizationModeSettingsStore {
    private static let enabledKey = "limitbar.organizationMode.enabled"
    private static let consentVersionKey = "limitbar.organizationMode.consentVersion"
    private static let consentDateKey = "limitbar.organizationMode.consentDate"
    private static let consentVersion = 1
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey) && defaults.integer(forKey: Self.consentVersionKey) == Self.consentVersion
    }

    @discardableResult
    public func enable(acknowledged: Bool, at date: Date = Date()) -> Bool {
        guard acknowledged else { return false }
        defaults.set(Self.consentVersion, forKey: Self.consentVersionKey)
        defaults.set(date, forKey: Self.consentDateKey)
        defaults.set(true, forKey: Self.enabledKey)
        return true
    }

    public func disable() { defaults.set(false, forKey: Self.enabledKey) }

    public func withEnabledAccess<T>(_ operation: () throws -> T) throws -> T {
        guard isEnabled else { throw OrganizationCapacityError.organizationModeDisabled }
        return try operation()
    }
}

public enum OrganizationProviderProduct: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude_code"
    case codex
}

public enum OrganizationCostProvenance: String, Codable, CaseIterable, Sendable {
    case providerReported = "provider_reported"
    case calculated
}

public enum OrganizationCostSubject: String, Codable, CaseIterable, Sendable {
    case subscriptionSeatCost = "subscription_seat_cost"
    case apiOverflowCost = "api_overflow_cost"
}

public struct OrganizationCostValue: Codable, Equatable, Sendable {
    public let amount: Decimal
    public let currency: String
    public let provenance: OrganizationCostProvenance

    public init(amount: Decimal, currency: String, provenance: OrganizationCostProvenance) throws {
        guard amount >= 0, amount <= 1_000_000_000,
              currency.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw OrganizationCapacityError.invalidValue("cost")
        }
        self.amount = amount
        self.currency = currency
        self.provenance = provenance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            amount: container.decode(Decimal.self, forKey: .amount),
            currency: container.decode(String.self, forKey: .currency),
            provenance: container.decode(OrganizationCostProvenance.self, forKey: .provenance)
        )
    }
}

public struct OrganizationDailyAggregate: Codable, Equatable, Sendable {
    public let day: Date
    public let providerProduct: OrganizationProviderProduct
    public let teamAlias: String
    public let cohortSize: Int
    public let usageUnits: Int64?
    public let blockedCapacityUserDays: Int?
    public let cacheReadUnits: Int64?
    public let uncachedInputUnits: Int64?
    public let peakConcurrency: Int?
    public let quotaEligibleUsers: Int?
    public let repeatedlyNearExhaustionUsers: Int?
    public let scheduledPeakBlockedMinutes: Int?
    public let offPeakAvailableMinutes: Int?
    public let subscriptionSeatCost: OrganizationCostValue?
    public let apiOverflowCost: OrganizationCostValue?

    public init(
        day: Date,
        providerProduct: OrganizationProviderProduct,
        teamAlias: String,
        cohortSize: Int,
        usageUnits: Int64? = nil,
        blockedCapacityUserDays: Int? = nil,
        cacheReadUnits: Int64? = nil,
        uncachedInputUnits: Int64? = nil,
        peakConcurrency: Int? = nil,
        quotaEligibleUsers: Int? = nil,
        repeatedlyNearExhaustionUsers: Int? = nil,
        scheduledPeakBlockedMinutes: Int? = nil,
        offPeakAvailableMinutes: Int? = nil,
        subscriptionSeatCost: OrganizationCostValue? = nil,
        apiOverflowCost: OrganizationCostValue? = nil
    ) throws {
        guard day.timeIntervalSince1970.isFinite,
              day.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0,
              Self.isValidAlias(teamAlias),
              (OrganizationDailyAggregateImporter.privacyThreshold...100_000).contains(cohortSize),
              usageUnits.map({ (0...1_000_000_000_000_000).contains($0) }) ?? true,
              blockedCapacityUserDays.map({ (0...cohortSize).contains($0) }) ?? true,
              (cacheReadUnits == nil) == (uncachedInputUnits == nil),
              cacheReadUnits.map({ (0...1_000_000_000_000_000).contains($0) }) ?? true,
              uncachedInputUnits.map({ (0...1_000_000_000_000_000).contains($0) }) ?? true,
              peakConcurrency.map({ (0...cohortSize).contains($0) }) ?? true,
              (quotaEligibleUsers == nil) == (repeatedlyNearExhaustionUsers == nil),
              quotaEligibleUsers.map({ (0...cohortSize).contains($0) }) ?? true,
              repeatedlyNearExhaustionUsers.map({ (0...(quotaEligibleUsers ?? 0)).contains($0) }) ?? true,
              (scheduledPeakBlockedMinutes == nil) == (offPeakAvailableMinutes == nil),
              scheduledPeakBlockedMinutes.map({ (0...(1_440 * cohortSize)).contains($0) }) ?? true,
              offPeakAvailableMinutes.map({ (0...(1_440 * cohortSize)).contains($0) }) ?? true else {
            throw OrganizationCapacityError.invalidValue("aggregate")
        }
        self.day = day
        self.providerProduct = providerProduct
        self.teamAlias = teamAlias
        self.cohortSize = cohortSize
        self.usageUnits = usageUnits
        self.blockedCapacityUserDays = blockedCapacityUserDays
        self.cacheReadUnits = cacheReadUnits
        self.uncachedInputUnits = uncachedInputUnits
        self.peakConcurrency = peakConcurrency
        self.quotaEligibleUsers = quotaEligibleUsers
        self.repeatedlyNearExhaustionUsers = repeatedlyNearExhaustionUsers
        self.scheduledPeakBlockedMinutes = scheduledPeakBlockedMinutes
        self.offPeakAvailableMinutes = offPeakAvailableMinutes
        self.subscriptionSeatCost = subscriptionSeatCost
        self.apiOverflowCost = apiOverflowCost
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            day: container.decode(Date.self, forKey: .day),
            providerProduct: container.decode(OrganizationProviderProduct.self, forKey: .providerProduct),
            teamAlias: container.decode(String.self, forKey: .teamAlias),
            cohortSize: container.decode(Int.self, forKey: .cohortSize),
            usageUnits: container.decodeIfPresent(Int64.self, forKey: .usageUnits),
            blockedCapacityUserDays: container.decodeIfPresent(Int.self, forKey: .blockedCapacityUserDays),
            cacheReadUnits: container.decodeIfPresent(Int64.self, forKey: .cacheReadUnits),
            uncachedInputUnits: container.decodeIfPresent(Int64.self, forKey: .uncachedInputUnits),
            peakConcurrency: container.decodeIfPresent(Int.self, forKey: .peakConcurrency),
            quotaEligibleUsers: container.decodeIfPresent(Int.self, forKey: .quotaEligibleUsers),
            repeatedlyNearExhaustionUsers: container.decodeIfPresent(Int.self, forKey: .repeatedlyNearExhaustionUsers),
            scheduledPeakBlockedMinutes: container.decodeIfPresent(Int.self, forKey: .scheduledPeakBlockedMinutes),
            offPeakAvailableMinutes: container.decodeIfPresent(Int.self, forKey: .offPeakAvailableMinutes),
            subscriptionSeatCost: container.decodeIfPresent(OrganizationCostValue.self, forKey: .subscriptionSeatCost),
            apiOverflowCost: container.decodeIfPresent(OrganizationCostValue.self, forKey: .apiOverflowCost)
        )
    }

    func validated() throws -> Self {
        try Self(
            day: day,
            providerProduct: providerProduct,
            teamAlias: teamAlias,
            cohortSize: cohortSize,
            usageUnits: usageUnits,
            blockedCapacityUserDays: blockedCapacityUserDays,
            cacheReadUnits: cacheReadUnits,
            uncachedInputUnits: uncachedInputUnits,
            peakConcurrency: peakConcurrency,
            quotaEligibleUsers: quotaEligibleUsers,
            repeatedlyNearExhaustionUsers: repeatedlyNearExhaustionUsers,
            scheduledPeakBlockedMinutes: scheduledPeakBlockedMinutes,
            offPeakAvailableMinutes: offPeakAvailableMinutes,
            subscriptionSeatCost: subscriptionSeatCost,
            apiOverflowCost: apiOverflowCost
        )
    }

    private static func isValidAlias(_ value: String) -> Bool {
        value.count == 29 && value.hasPrefix("team-") && value.dropFirst(5).utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct OrganizationImportProvenance: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let providerProducts: [OrganizationProviderProduct]
    public let period: String
    public let timezone: String
    public let importedAt: Date
    public let fileDigest: String
    public let acceptedRecordCount: Int
    public let suppressedRecordCount: Int
    public let privacyThreshold: Int
}

public struct OrganizationImportBatch: Equatable, Sendable {
    public let aggregates: [OrganizationDailyAggregate]
    public let provenance: OrganizationImportProvenance
}

public protocol OrganizationTeamAliasing: Sendable {
    func alias(for teamIdentity: UUID) throws -> String
}

public struct OrganizationTeamAliasKey: OrganizationTeamAliasing, Sendable {
    private let key: SymmetricKey

    public init(keyData: Data) throws {
        guard keyData.count == 32 else { throw OrganizationCapacityError.aliasKeyUnavailable }
        key = SymmetricKey(data: keyData)
    }

    public func alias(for teamIdentity: UUID) throws -> String {
        let authentication = HMAC<SHA256>.authenticationCode(for: Data(teamIdentity.uuidString.lowercased().utf8), using: key)
        return "team-" + authentication.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public final class OrganizationTeamAliasKeyFile: @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func loadOrCreate() throws -> OrganizationTeamAliasKey {
        if fileManager.fileExists(atPath: url.path) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 32 else {
                throw OrganizationCapacityError.aliasKeyUnavailable
            }
            return try OrganizationTeamAliasKey(keyData: Data(contentsOf: url, options: .uncached))
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OrganizationCapacityError.aliasKeyUnavailable
        }
        let data = Data(bytes)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return try OrganizationTeamAliasKey(keyData: data)
        } catch {
            try? fileManager.removeItem(at: url)
            throw OrganizationCapacityError.aliasKeyUnavailable
        }
    }
}

public enum OrganizationDailyAggregateImporter {
    public static let schemaVersion = "limitbar.organization.daily.v1"
    public static let privacyThreshold = 5
    public static let maximumFileSize = 8 * 1_024 * 1_024

    private static let envelopeFields: Set<String> = [
        "schema_version", "administrator_reviewed", "aggregation_period", "timezone", "records"
    ]
    private static let recordFields: Set<String> = [
        "day", "provider_product", "team_identity", "cohort_size", "complete_day", "usage_units",
        "blocked_capacity_user_days", "cache_read_units", "uncached_input_units", "peak_concurrency",
        "quota_eligible_users", "repeatedly_near_exhaustion_users", "scheduled_peak_blocked_minutes",
        "off_peak_available_minutes", "subscription_seat_cost", "api_overflow_cost"
    ]
    private static let costFields: Set<String> = ["amount", "currency", "provenance"]
    private static let prohibitedKeys: Set<String> = [
        "email", "email_address", "name", "employee_name", "api_key_name", "organization_id",
        "terminal", "terminal_id", "terminal_type", "actor_id", "raw_actor_id", "user_id", "prompt",
        "code", "source_code", "transcript", "path", "file_path", "attributes", "custom_attributes"
    ]

    public static func importData(
        _ data: Data,
        aliaser: any OrganizationTeamAliasing,
        now: Date = Date()
    ) throws -> OrganizationImportBatch {
        guard !data.isEmpty, data.count <= maximumFileSize,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OrganizationCapacityError.malformedFile
        }
        try validateKeys(Set(root.keys), allowed: envelopeFields)
        guard root["schema_version"] as? String == schemaVersion else { throw OrganizationCapacityError.unsupportedSchema }
        guard root["administrator_reviewed"] as? Bool == true else { throw OrganizationCapacityError.administratorReviewRequired }
        guard root["aggregation_period"] as? String == "daily", root["timezone"] as? String == "UTC" else {
            throw OrganizationCapacityError.unsupportedAggregation
        }
        guard let rawRecords = root["records"] as? [[String: Any]], !rawRecords.isEmpty, rawRecords.count <= 10_000 else {
            throw OrganizationCapacityError.malformedFile
        }

        let calendar = utcCalendar
        let today = calendar.startOfDay(for: now)
        var records: [OrganizationDailyAggregate] = []
        var identities = Set<String>()
        var products = Set<OrganizationProviderProduct>()
        var suppressed = 0

        for raw in rawRecords {
            try validateKeys(Set(raw.keys), allowed: recordFields)
            guard let dayText = raw["day"] as? String,
                  let day = dayFormatter.date(from: dayText), dayFormatter.string(from: day) == dayText, day < today,
                  let productText = raw["provider_product"] as? String,
                  let product = OrganizationProviderProduct(rawValue: productText),
                  let teamIdentityText = raw["team_identity"] as? String,
                  let teamIdentity = canonicalTeamIdentity(teamIdentityText),
                  let cohortSize = strictInt(raw["cohort_size"]), (1...100_000).contains(cohortSize) else {
                throw OrganizationCapacityError.invalidValue("record identity")
            }
            guard raw["complete_day"] as? Bool == true else { throw OrganizationCapacityError.partialDay }
            let identity = "\(dayText)|\(product.rawValue)|\(teamIdentity.uuidString.lowercased())"
            guard identities.insert(identity).inserted else { throw OrganizationCapacityError.duplicateRecord }
            products.insert(product)

            let values = try validatedValues(raw, cohortSize: cohortSize)
            guard cohortSize >= privacyThreshold else {
                suppressed += 1
                continue
            }
            let alias = try aliaser.alias(for: teamIdentity)
            guard alias.hasPrefix("team-"), alias.count == 29 else { throw OrganizationCapacityError.aliasKeyUnavailable }
            records.append(try OrganizationDailyAggregate(
                day: day,
                providerProduct: product,
                teamAlias: alias,
                cohortSize: cohortSize,
                usageUnits: values.usage,
                blockedCapacityUserDays: values.blocked,
                cacheReadUnits: values.cacheRead,
                uncachedInputUnits: values.uncached,
                peakConcurrency: values.concurrency,
                quotaEligibleUsers: values.eligible,
                repeatedlyNearExhaustionUsers: values.repeated,
                scheduledPeakBlockedMinutes: values.scheduledBlocked,
                offPeakAvailableMinutes: values.offPeak,
                subscriptionSeatCost: values.seatCost,
                apiOverflowCost: values.apiCost
            ))
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return OrganizationImportBatch(
            aggregates: records,
            provenance: OrganizationImportProvenance(
                schemaVersion: schemaVersion,
                providerProducts: products.sorted { $0.rawValue < $1.rawValue },
                period: "daily",
                timezone: "UTC",
                importedAt: now,
                fileDigest: digest,
                acceptedRecordCount: records.count,
                suppressedRecordCount: suppressed,
                privacyThreshold: privacyThreshold
            )
        )
    }

    private struct Values {
        let usage: Int64?
        let blocked: Int?
        let cacheRead: Int64?
        let uncached: Int64?
        let concurrency: Int?
        let eligible: Int?
        let repeated: Int?
        let scheduledBlocked: Int?
        let offPeak: Int?
        let seatCost: OrganizationCostValue?
        let apiCost: OrganizationCostValue?
    }

    private static func validatedValues(_ raw: [String: Any], cohortSize: Int) throws -> Values {
        let usage = try optionalInt64(raw, "usage_units", maximum: 1_000_000_000_000_000)
        let blocked = try optionalInt(raw, "blocked_capacity_user_days", maximum: cohortSize)
        let cacheRead = try optionalInt64(raw, "cache_read_units", maximum: 1_000_000_000_000_000)
        let uncached = try optionalInt64(raw, "uncached_input_units", maximum: 1_000_000_000_000_000)
        guard (cacheRead == nil) == (uncached == nil) else { throw OrganizationCapacityError.invalidValue("cache evidence") }
        let concurrency = try optionalInt(raw, "peak_concurrency", maximum: cohortSize)
        let eligible = try optionalInt(raw, "quota_eligible_users", maximum: cohortSize)
        let repeated = try optionalInt(raw, "repeatedly_near_exhaustion_users", maximum: cohortSize)
        guard (eligible == nil) == (repeated == nil), repeated.map({ $0 <= (eligible ?? 0) }) ?? true else {
            throw OrganizationCapacityError.invalidValue("quota evidence")
        }
        let scheduled = try optionalInt(raw, "scheduled_peak_blocked_minutes", maximum: 1_440 * cohortSize)
        let offPeak = try optionalInt(raw, "off_peak_available_minutes", maximum: 1_440 * cohortSize)
        guard (scheduled == nil) == (offPeak == nil) else { throw OrganizationCapacityError.invalidValue("scenario evidence") }
        return Values(
            usage: usage,
            blocked: blocked,
            cacheRead: cacheRead,
            uncached: uncached,
            concurrency: concurrency,
            eligible: eligible,
            repeated: repeated,
            scheduledBlocked: scheduled,
            offPeak: offPeak,
            seatCost: try cost(raw["subscription_seat_cost"]),
            apiCost: try cost(raw["api_overflow_cost"])
        )
    }

    private static func cost(_ value: Any?) throws -> OrganizationCostValue? {
        guard let value else { return nil }
        guard let raw = value as? [String: Any] else { throw OrganizationCapacityError.invalidValue("cost") }
        try validateKeys(Set(raw.keys), allowed: costFields)
        guard let number = raw["amount"] as? NSNumber,
              !isBoolean(number), number.doubleValue.isFinite,
              let currency = raw["currency"] as? String,
              let provenanceText = raw["provenance"] as? String,
              let provenance = OrganizationCostProvenance(rawValue: provenanceText) else {
            throw OrganizationCapacityError.invalidValue("cost")
        }
        return try OrganizationCostValue(amount: Decimal(number.doubleValue), currency: currency, provenance: provenance)
    }

    private static func validateKeys(_ keys: Set<String>, allowed: Set<String>) throws {
        if let key = keys.first(where: { prohibitedKeys.contains($0.lowercased()) }) {
            throw OrganizationCapacityError.prohibitedField(key)
        }
        if let key = keys.subtracting(allowed).sorted().first { throw OrganizationCapacityError.unknownField(key) }
    }

    private static func optionalInt(_ raw: [String: Any], _ key: String, maximum: Int) throws -> Int? {
        guard raw[key] != nil else { return nil }
        guard let value = strictInt(raw[key]), (0...maximum).contains(value) else {
            throw OrganizationCapacityError.invalidValue(key)
        }
        return value
    }

    private static func optionalInt64(_ raw: [String: Any], _ key: String, maximum: Int64) throws -> Int64? {
        guard raw[key] != nil else { return nil }
        guard let number = raw[key] as? NSNumber, !isBoolean(number), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(maximum) else {
            throw OrganizationCapacityError.invalidValue(key)
        }
        return number.int64Value
    }

    private static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func canonicalTeamIdentity(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return nil }
        return uuid
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = utcCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}

public struct OrganizationMetricDistribution: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let minimum: Double
    public let median: Double
    public let maximum: Double
}

public struct OrganizationCostSummary: Codable, Equatable, Sendable {
    public let providerProduct: OrganizationProviderProduct
    public let subject: OrganizationCostSubject
    public let provenance: OrganizationCostProvenance
    public let currency: String
    public let amount: Decimal
}

public struct OrganizationProviderCapacitySummary: Codable, Equatable, Sendable {
    public let providerProduct: OrganizationProviderProduct
    public let blockedCapacityDays: [Date]?
    public let dailyTopTeamShare: OrganizationMetricDistribution?
    public let dailyConcentrationIndex: OrganizationMetricDistribution?
    public let cacheEfficiency: OrganizationMetricDistribution?
    public let peakConcurrency: OrganizationMetricDistribution?
    public let repeatedNearExhaustionShare: OrganizationMetricDistribution?
    public let costs: [OrganizationCostSummary]
}

public struct OrganizationCapacitySummary: Codable, Equatable, Sendable {
    public let providers: [OrganizationProviderCapacitySummary]
    public let acceptedRecordCount: Int
    public let suppressedRecordCount: Int
}

public struct OrganizationScheduleShiftScenario: Codable, Equatable, Sendable {
    public let providerProduct: OrganizationProviderProduct
    public let shiftFraction: Double
    public let observedScheduledPeakBlockedMinutes: Int
    public let observedOffPeakAvailableMinutes: Int
    public let possibleBlockedMinutesReductionLowerBound: Int
    public let possibleBlockedMinutesReductionUpperBound: Int
    public let assumptions: [String]
    public let limitation: String
}

public enum OrganizationCapacityCalculator {
    public static func summary(
        aggregates: [OrganizationDailyAggregate],
        provenances: [OrganizationImportProvenance]
    ) throws -> OrganizationCapacitySummary {
        let validated = try aggregates.map { try $0.validated() }
        let providers = Dictionary(grouping: validated, by: \.providerProduct).map { product, records in
            providerSummary(product: product, aggregates: records)
        }.sorted { $0.providerProduct.rawValue < $1.providerProduct.rawValue }
        return OrganizationCapacitySummary(
            providers: providers,
            acceptedRecordCount: provenances.reduce(0) { $0 + $1.acceptedRecordCount },
            suppressedRecordCount: provenances.reduce(0) { $0 + $1.suppressedRecordCount }
        )
    }

    private static func providerSummary(
        product: OrganizationProviderProduct,
        aggregates: [OrganizationDailyAggregate]
    ) -> OrganizationProviderCapacitySummary {
        let byDay = Dictionary(grouping: aggregates, by: \.day)
        let hasBlockedCapacityEvidence = aggregates.contains { $0.blockedCapacityUserDays != nil }
        let blockedDays = hasBlockedCapacityEvidence ? byDay.compactMap { day, records in
            records.compactMap(\.blockedCapacityUserDays).reduce(0, +) > 0 ? day : nil
        }.sorted() : nil
        let concentration = byDay.values.compactMap { records -> (Double, Double)? in
            let values = records.compactMap(\.usageUnits).map(Double.init)
            let total = values.reduce(0, +)
            guard values.count == records.count, values.count > 1, total > 0 else { return nil }
            let shares = values.map { $0 / total }
            return (shares.max() ?? 0, shares.reduce(0) { $0 + $1 * $1 })
        }
        let cache = aggregates.compactMap { record -> Double? in
            guard let read = record.cacheReadUnits, let uncached = record.uncachedInputUnits, read + uncached > 0 else { return nil }
            return Double(read) / Double(read + uncached)
        }
        let concurrency = aggregates.compactMap(\.peakConcurrency).map(Double.init)
        let exhaustion = aggregates.compactMap { record -> Double? in
            guard let eligible = record.quotaEligibleUsers, let repeated = record.repeatedlyNearExhaustionUsers, eligible > 0 else { return nil }
            return Double(repeated) / Double(eligible)
        }
        return OrganizationProviderCapacitySummary(
            providerProduct: product,
            blockedCapacityDays: blockedDays,
            dailyTopTeamShare: distribution(concentration.map(\.0)),
            dailyConcentrationIndex: distribution(concentration.map(\.1)),
            cacheEfficiency: distribution(cache),
            peakConcurrency: distribution(concurrency),
            repeatedNearExhaustionShare: distribution(exhaustion),
            costs: costSummaries(aggregates)
        )
    }

    public static func scheduleShiftScenario(
        aggregates: [OrganizationDailyAggregate],
        shiftFraction: Double
    ) throws -> OrganizationScheduleShiftScenario? {
        guard shiftFraction.isFinite, (0...0.5).contains(shiftFraction) else { return nil }
        let validated = try aggregates.map { try $0.validated() }
        let products = Set(validated.map(\.providerProduct))
        guard products.count == 1, let product = products.first else { return nil }
        let supported = validated.filter { $0.scheduledPeakBlockedMinutes != nil && $0.offPeakAvailableMinutes != nil }
        guard !supported.isEmpty else { return nil }
        let blocked = supported.compactMap(\.scheduledPeakBlockedMinutes).reduce(0, +)
        let offPeak = supported.compactMap(\.offPeakAvailableMinutes).reduce(0, +)
        let upper = min(Int((Double(blocked) * shiftFraction).rounded(.down)), offPeak)
        return OrganizationScheduleShiftScenario(
            providerProduct: product,
            shiftFraction: shiftFraction,
            observedScheduledPeakBlockedMinutes: blocked,
            observedOffPeakAvailableMinutes: offPeak,
            possibleBlockedMinutesReductionLowerBound: 0,
            possibleBlockedMinutesReductionUpperBound: upper,
            assumptions: [
                "The selected completed days are representative of the proposed schedule.",
                "The shifted batch work can use measured off-peak capacity without displacing other work.",
                "Provider quota behavior and workload demand remain otherwise unchanged."
            ],
            limitation: "This bounded scenario is not a forecast or guarantee of reduced blocking, recovered capacity, productivity, quality, or developer value."
        )
    }

    public static func scheduleShiftScenarios(
        aggregates: [OrganizationDailyAggregate],
        shiftFraction: Double
    ) throws -> [OrganizationScheduleShiftScenario] {
        let validated = try aggregates.map { try $0.validated() }
        return try Dictionary(grouping: validated, by: \.providerProduct).keys.sorted { $0.rawValue < $1.rawValue }.compactMap { product in
            try scheduleShiftScenario(
                aggregates: validated.filter { $0.providerProduct == product },
                shiftFraction: shiftFraction
            )
        }
    }

    private static func distribution(_ values: [Double]) -> OrganizationMetricDistribution? {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return OrganizationMetricDistribution(sampleCount: sorted.count, minimum: first, median: median, maximum: last)
    }

    private static func costSummaries(_ aggregates: [OrganizationDailyAggregate]) -> [OrganizationCostSummary] {
        struct Key: Hashable {
            let providerProduct: OrganizationProviderProduct
            let subject: OrganizationCostSubject
            let provenance: OrganizationCostProvenance
            let currency: String
        }
        var totals: [Key: Decimal] = [:]
        for aggregate in aggregates {
            if let value = aggregate.subscriptionSeatCost {
                totals[Key(providerProduct: aggregate.providerProduct, subject: .subscriptionSeatCost, provenance: value.provenance, currency: value.currency), default: 0] += value.amount
            }
            if let value = aggregate.apiOverflowCost {
                totals[Key(providerProduct: aggregate.providerProduct, subject: .apiOverflowCost, provenance: value.provenance, currency: value.currency), default: 0] += value.amount
            }
        }
        return totals.map { OrganizationCostSummary(providerProduct: $0.key.providerProduct, subject: $0.key.subject, provenance: $0.key.provenance, currency: $0.key.currency, amount: $0.value) }
            .sorted {
                let leftSubject = $0.subject == .subscriptionSeatCost ? 0 : 1
                let rightSubject = $1.subject == .subscriptionSeatCost ? 0 : 1
                return ($0.providerProduct.rawValue, leftSubject, $0.provenance.rawValue, $0.currency)
                    < ($1.providerProduct.rawValue, rightSubject, $1.provenance.rawValue, $1.currency)
            }
    }
}

public struct OrganizationCapacityExport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let generatedAt: Date
    public let privacyThreshold: Int
    public let summary: OrganizationCapacitySummary
    public let scenarios: [OrganizationScheduleShiftScenario]
    public let sourceSchemas: [String]
    public let providerProducts: [OrganizationProviderProduct]
    public let aggregationPeriod: String
    public let timezone: String
    public let limitations: [String]
}

public enum OrganizationCapacityExporter {
    public static func make(
        aggregates: [OrganizationDailyAggregate],
        provenances: [OrganizationImportProvenance],
        shiftFraction: Double? = nil,
        generatedAt: Date = Date()
    ) throws -> Data {
        let report = OrganizationCapacityExport(
            schemaVersion: "limitbar.organization.capacity-export.v1",
            generatedAt: generatedAt,
            privacyThreshold: OrganizationDailyAggregateImporter.privacyThreshold,
            summary: try OrganizationCapacityCalculator.summary(aggregates: aggregates, provenances: provenances),
            scenarios: try shiftFraction.map {
                try OrganizationCapacityCalculator.scheduleShiftScenarios(aggregates: aggregates, shiftFraction: $0)
            } ?? [],
            sourceSchemas: Array(Set(provenances.map(\.schemaVersion))).sorted(),
            providerProducts: Array(Set(provenances.flatMap(\.providerProducts))).sorted { $0.rawValue < $1.rawValue },
            aggregationPeriod: "daily",
            timezone: "UTC",
            limitations: [
                "Outputs are distributions over administrator-reviewed daily aggregates, not individual measures.",
                "Activity and usage are not measures of productivity, performance, quality, or developer value.",
                "Subscription quota, seat cost, API overflow cost, Provider-Reported Cost, and Calculated Cost remain separate subjects."
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(0x0A)
        return data
    }
}
