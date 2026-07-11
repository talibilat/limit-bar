import Foundation

public enum ClaudeRateLimitGroup: String, Codable, Equatable, Sendable {
    case session
    case weekly
    case other

    public init(rawGroup: String?) {
        self = ClaudeRateLimitGroup(rawValue: rawGroup ?? "") ?? .other
    }
}

public enum ClaudeRateLimitSeverity: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case exceeded
    case unknown

    public init(rawSeverity: String?) {
        self = ClaudeRateLimitSeverity(rawValue: rawSeverity ?? "") ?? .unknown
    }
}

public struct ClaudeRateLimit: Equatable, Sendable {
    public let kind: String
    public let group: ClaudeRateLimitGroup
    public let percentUsed: Double
    public let severity: ClaudeRateLimitSeverity
    public let resetsAt: Date?
    public let scopeDisplayName: String?
    public let isActive: Bool

    public init(
        kind: String,
        group: ClaudeRateLimitGroup,
        percentUsed: Double,
        severity: ClaudeRateLimitSeverity,
        resetsAt: Date?,
        scopeDisplayName: String?,
        isActive: Bool
    ) {
        self.kind = kind
        self.group = group
        self.percentUsed = percentUsed
        self.severity = severity
        self.resetsAt = resetsAt
        self.scopeDisplayName = scopeDisplayName
        self.isActive = isActive
    }

    public var displayLabel: String {
        if let scopeDisplayName {
            return group == .session ? "Session (\(scopeDisplayName))" : "Weekly (\(scopeDisplayName))"
        }
        switch kind {
        case "session":
            return "Session (5 hours)"
        case "weekly_all":
            return "Weekly (all usage)"
        default:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var percentRemaining: Double {
        max(0, 100 - percentUsed)
    }
}

public struct ClaudeRateLimitSnapshot: Equatable, Sendable {
    public let limits: [ClaudeRateLimit]
    public let fetchedAt: Date

    public init(limits: [ClaudeRateLimit], fetchedAt: Date) {
        self.limits = limits
        self.fetchedAt = fetchedAt
    }
}

public enum ClaudeRateLimitFailure: Error, Equatable, Sendable {
    case expiredLogin
    case requestRejected
    case networkUnavailable
    case malformedResponse

    public var displayText: String {
        switch self {
        case .expiredLogin:
            "Claude login expired. Open Claude Code to refresh it."
        case .requestRejected:
            "Claude usage request was rejected."
        case .networkUnavailable:
            "Network unavailable."
        case .malformedResponse:
            "Claude usage response was not understood."
        }
    }
}

public enum ClaudeUsageResponseMapper {
    private struct RawResponse: Decodable {
        struct RawWindow: Decodable {
            let utilization: Double?
            let resets_at: String?
        }

        struct RawScopeModel: Decodable {
            let display_name: String?
        }

        struct RawScope: Decodable {
            let model: RawScopeModel?
            let surface: RawScopeModel?
        }

        struct RawLimit: Decodable {
            let kind: String?
            let group: String?
            let percent: Double?
            let severity: String?
            let resets_at: String?
            let scope: RawScope?
            let is_active: Bool?
        }

        let five_hour: RawWindow?
        let seven_day: RawWindow?
        let limits: [RawLimit]?
    }

    public static func rateLimits(from data: Data, fetchedAt: Date) throws -> ClaudeRateLimitSnapshot {
        guard let raw = try? JSONDecoder().decode(RawResponse.self, from: data) else {
            throw ClaudeRateLimitFailure.malformedResponse
        }

        var limits: [ClaudeRateLimit] = (raw.limits ?? []).compactMap { rawLimit in
            guard let kind = rawLimit.kind, let percent = rawLimit.percent else {
                return nil
            }
            return ClaudeRateLimit(
                kind: kind,
                group: ClaudeRateLimitGroup(rawGroup: rawLimit.group),
                percentUsed: percent,
                severity: ClaudeRateLimitSeverity(rawSeverity: rawLimit.severity),
                resetsAt: rawLimit.resets_at.flatMap(parseTimestamp),
                scopeDisplayName: rawLimit.scope.flatMap { $0.model?.display_name ?? $0.surface?.display_name },
                isActive: rawLimit.is_active ?? false
            )
        }

        if limits.isEmpty {
            if let fiveHour = raw.five_hour, let utilization = fiveHour.utilization {
                limits.append(ClaudeRateLimit(
                    kind: "session",
                    group: .session,
                    percentUsed: utilization,
                    severity: .unknown,
                    resetsAt: fiveHour.resets_at.flatMap(parseTimestamp),
                    scopeDisplayName: nil,
                    isActive: false
                ))
            }
            if let sevenDay = raw.seven_day, let utilization = sevenDay.utilization {
                limits.append(ClaudeRateLimit(
                    kind: "weekly_all",
                    group: .weekly,
                    percentUsed: utilization,
                    severity: .unknown,
                    resetsAt: sevenDay.resets_at.flatMap(parseTimestamp),
                    scopeDisplayName: nil,
                    isActive: false
                ))
            }
        }

        guard !limits.isEmpty else {
            throw ClaudeRateLimitFailure.malformedResponse
        }

        return ClaudeRateLimitSnapshot(limits: limits, fetchedAt: fetchedAt)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

public struct ClaudeOAuthUsageClient: Sendable {
    private let httpClient: any HTTPClient
    private let baseURL: URL

    public init(httpClient: any HTTPClient, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    public func fetchRateLimits(accessToken: String, now: Date = Date()) async -> Result<ClaudeRateLimitSnapshot, ClaudeRateLimitFailure> {
        let request = HTTPRequest(
            url: baseURL.appendingPathComponent("api/oauth/usage"),
            method: .get,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
                "Content-Type": "application/json"
            ]
        )

        let response: HTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch {
            return .failure(.networkUnavailable)
        }

        switch response.statusCode {
        case 200:
            do {
                return .success(try ClaudeUsageResponseMapper.rateLimits(from: response.data, fetchedAt: now))
            } catch {
                return .failure(.malformedResponse)
            }
        case 401, 403:
            return .failure(.expiredLogin)
        default:
            return .failure(.requestRejected)
        }
    }
}
