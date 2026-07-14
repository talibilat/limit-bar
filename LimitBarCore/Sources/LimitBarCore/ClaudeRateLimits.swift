import Foundation
import Observation

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

    // Individual plans (Pro, Max) get per-model scoped limits alongside the
    // account-wide session/weekly windows. Team and Enterprise seats share a
    // pooled allowance, so only the account-wide windows are shown; a scoped
    // breakdown would describe the seat's slice of a shared pool, not a
    // personal limit, the same way Codex business seats only expose credits.
    private static let individualSubscriptionTypes: Set<String> = ["pro", "max"]

    public func displayLimits(forSubscriptionType subscriptionType: String?) -> [ClaudeRateLimit] {
        let isIndividual = subscriptionType.map { Self.individualSubscriptionTypes.contains($0.lowercased()) } ?? false
        return isIndividual ? limits : limits.filter { $0.scopeDisplayName == nil }
    }
}

public enum ClaudeRateLimitFailure: Error, Equatable, Sendable {
    case expiredLogin
    case requestRejected
    case networkUnavailable
    case malformedResponse
    case cancelled

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
        case .cancelled:
            ""
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
            guard let kind = rawLimit.kind, let percent = rawLimit.percent,
                  percent.isFinite, (0...100).contains(percent) else {
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
            if let fiveHour = raw.five_hour, let utilization = fiveHour.utilization,
               utilization.isFinite, (0...100).contains(utilization) {
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
            if let sevenDay = raw.seven_day, let utilization = sevenDay.utilization,
               utilization.isFinite, (0...100).contains(utilization) {
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

public protocol ClaudeRateLimitsFetching: Sendable {
    func fetchRateLimits(accessToken: String) async -> Result<ClaudeRateLimitSnapshot, ClaudeRateLimitFailure>
}

public struct ClaudeOAuthUsageClient: Sendable, ClaudeRateLimitsFetching {
    private let httpClient: any HTTPClient
    private let baseURL: URL

    public init(httpClient: any HTTPClient, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    public func fetchRateLimits(accessToken: String) async -> Result<ClaudeRateLimitSnapshot, ClaudeRateLimitFailure> {
        await fetchRateLimits(accessToken: accessToken, now: Date())
    }

    public func fetchRateLimits(accessToken: String, now: Date) async -> Result<ClaudeRateLimitSnapshot, ClaudeRateLimitFailure> {
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
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .failure(.cancelled) }
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

public enum ClaudeRateLimitsModelState: Equatable, Sendable {
    case loading
    case notConnected
    case authorizationRequired
    case loaded(ClaudeRateLimitSnapshot, subscription: String?)
    case failed(String)
}

@MainActor
@Observable
public final class ClaudeRateLimitsModel {
    public private(set) var state: ClaudeRateLimitsModelState
    public private(set) var isPresent = true
    public private(set) var isRefreshing = false

    private let credentials: any ClaudeCredentialProviding
    private let client: any ClaudeRateLimitsFetching

    public init(
        credentials: any ClaudeCredentialProviding,
        client: any ClaudeRateLimitsFetching,
        state: ClaudeRateLimitsModelState = .loading
    ) {
        self.credentials = credentials
        self.client = client
        self.state = state
    }

    public func appeared() async {
        await refresh(intent: .passive)
    }

    public func connect() async {
        await refresh(intent: .interactive)
    }

    public func refresh() async {
        await refresh(intent: .passive)
    }

    private func refresh(intent: ClaudeCredentialIntent) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let credential: ClaudeCodeOAuthCredential
        switch await credentials.credential(intent: intent) {
        case let .credential(found):
            isPresent = true
            credential = found
        case .absent:
            isPresent = true
            state = .notConnected
            return
        case .failure(.interactionRequired):
            isPresent = true
            state = .authorizationRequired
            return
        case .failure(.userCancelled):
            return
        case .failure(.authFailed) where intent == .interactive:
            isPresent = true
            state = .authorizationRequired
            return
        case let .failure(error):
            isPresent = true
            state = .failed(error.displayText)
            return
        }

        switch await client.fetchRateLimits(accessToken: credential.accessToken) {
        case let .success(snapshot):
            state = .loaded(snapshot, subscription: credential.subscriptionType)
        case .failure(.cancelled):
            return
        case let .failure(failure):
            if failure == .expiredLogin {
                await credentials.invalidate()
            }
            state = .failed(failure.displayText)
        }
    }
}

private extension ClaudeCredentialError {
    var displayText: String {
        switch self {
        case .interactionRequired:
            "Authorization is required to read the Claude Code login."
        case .userCancelled:
            ""
        case .authFailed:
            "Claude Code login authorization failed."
        case .notAvailable:
            "The macOS Keychain is unavailable."
        case .noAccess:
            "LimitBar cannot access the Claude Code login."
        case .malformedCredential:
            "The Claude Code login was not understood."
        case .unexpected:
            "The Claude Code login could not be read."
        }
    }
}
