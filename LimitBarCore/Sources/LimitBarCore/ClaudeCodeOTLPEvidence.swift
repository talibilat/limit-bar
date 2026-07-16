import CryptoKit
import Foundation

public enum ClaudeCodeTokenType: String, Codable, CaseIterable, Equatable, Sendable {
    case input
    case output
    case cacheRead = "cacheRead"
    case cacheCreation = "cacheCreation"
}

public enum ClaudeCodeOTLPSourceStatus: String, Codable, Equatable, Sendable {
    case supported
    case malformed
    case unsupportedVersion = "unsupported_version"
    case noClaudeCodeMetric = "no_claude_code_metric"
    case unsupportedMetric = "unsupported_metric"
}

public enum ClaudeCodeOmittedFieldCategory: String, Codable, Equatable, Sendable {
    case contentBearing = "content_bearing"
    case accountLabel = "account_label"
    case privatePath = "private_path"
    case arbitraryAttribute = "arbitrary_attribute"
}

public enum ClaudeEvidenceLimitation: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case receiverNotConfigured = "receiver_not_configured"
    case accountBindingUnavailable = "account_binding_unavailable"
    case quotaAccountScopeUnavailable = "quota_account_scope_unavailable"
    case accountTransitionUnverified = "account_transition_unverified"
    case missingEvidenceBoundary = "missing_evidence_boundary"
    case partialCoverage = "partial_coverage"
    case evidenceGap = "evidence_gap"
    case incompatibleUnit = "incompatible_unit"
    case unsupportedEvidence = "unsupported_evidence"
}

public enum ClaudeCodeOTLPEvidenceValidationError: Error, Equatable {
    case invalidInterval
    case invalidTokenCount
    case invalidModel
    case invalidDigest
    case unsupportedVersion
}

public struct ClaudeCodeOTLPEvidence: Encodable, Equatable, Sendable {
    public let identity: String
    public let accountIdentity: String
    public let sessionIdentity: String
    public let intervalStart: Date
    public let intervalEnd: Date
    public let model: String
    public let tokenType: ClaudeCodeTokenType
    public let tokenCount: Int64
    public let sourceVersion: String
    public let adapterVersion: String

    private init(
        identity: String,
        accountIdentity: String,
        sessionIdentity: String,
        intervalStart: Date,
        intervalEnd: Date,
        model: String,
        tokenType: ClaudeCodeTokenType,
        tokenCount: Int64,
        sourceVersion: String,
        adapterVersion: String
    ) {
        self.identity = identity
        self.accountIdentity = accountIdentity
        self.sessionIdentity = sessionIdentity
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.model = model
        self.tokenType = tokenType
        self.tokenCount = tokenCount
        self.sourceVersion = sourceVersion
        self.adapterVersion = adapterVersion
    }

    public static func validated(
        identity: String,
        accountIdentity: String,
        sessionIdentity: String,
        intervalStart: Date,
        intervalEnd: Date,
        model: String,
        tokenType: ClaudeCodeTokenType,
        tokenCount: Int64,
        sourceVersion: String,
        adapterVersion: String
    ) throws -> Self {
        guard intervalStart.timeIntervalSince1970.isFinite,
              intervalEnd.timeIntervalSince1970.isFinite,
              intervalStart < intervalEnd else { throw ClaudeCodeOTLPEvidenceValidationError.invalidInterval }
        guard tokenCount >= 0 else { throw ClaudeCodeOTLPEvidenceValidationError.invalidTokenCount }
        guard validModel(model) else { throw ClaudeCodeOTLPEvidenceValidationError.invalidModel }
        guard validDigest(identity), validDigest(accountIdentity), validDigest(sessionIdentity) else {
            throw ClaudeCodeOTLPEvidenceValidationError.invalidDigest
        }
        guard sourceVersion == ClaudeCodeOTLPEvidenceAdapter.supportedSourceVersion,
              adapterVersion == ClaudeCodeOTLPEvidenceAdapter.adapterVersion else {
            throw ClaudeCodeOTLPEvidenceValidationError.unsupportedVersion
        }
        return Self(
            identity: identity,
            accountIdentity: accountIdentity,
            sessionIdentity: sessionIdentity,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            model: model,
            tokenType: tokenType,
            tokenCount: tokenCount,
            sourceVersion: sourceVersion,
            adapterVersion: adapterVersion
        )
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validModel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.first?.isASCIIAlphaNumeric == true
            && value.allSatisfy { $0.isASCIIAlphaNumeric || $0 == "." || $0 == "_" || $0 == "-" }
            && !value.lowercased().hasPrefix("sk-")
    }
}

public struct ClaudeCodeOTLPScanResult: Equatable, Sendable {
    public let sourceStatus: ClaudeCodeOTLPSourceStatus
    public let evidence: [ClaudeCodeOTLPEvidence]
    public let omittedFieldCategories: [ClaudeCodeOmittedFieldCategory]
    public let limitations: [ClaudeEvidenceLimitation]
    public let lastVerified: String
}

public enum ClaudeCodeOTLPEvidenceAdapter {
    public static let adapterVersion = "claude-code-otlp-http-json-2.1.207-v1"
    public static let supportedSourceVersion = "2.1.207"
    public static let lastVerified = "2026-07-15"

    public static func scan(data: Data, identityKey: Data) -> ClaudeCodeOTLPScanResult {
        guard !identityKey.isEmpty, data.count <= 8 * 1_024 * 1_024,
              let request = try? JSONDecoder().decode(ExportMetricsRequest.self, from: data) else {
            return result(.malformed)
        }

        var foundClaudeMetric = false
        var foundUnsupportedMetric = false
        var foundUnsupportedVersion = false
        var limitations: [ClaudeEvidenceLimitation] = []
        var evidence: [ClaudeCodeOTLPEvidence] = []
        for resourceMetrics in request.resourceMetrics {
            for scope in resourceMetrics.scopeMetrics {
                for metric in scope.metrics where metric.name == "claude_code.token.usage" {
                    foundClaudeMetric = true
                    guard let sum = metric.sum, sum.aggregationTemporality == 1, sum.isMonotonic else {
                        foundUnsupportedMetric = true
                        continue
                    }
                    for point in sum.dataPoints {
                        let pointAttributes = attributes(point.attributes)
                        guard let sourceVersion = pointAttributes["app.version"], sourceVersion == supportedSourceVersion else {
                            foundUnsupportedVersion = true
                            continue
                        }
                        guard let startNanosText = point.startTimeUnixNano,
                              let startNanos = UInt64(startNanosText), startNanos > 0 else {
                            foundUnsupportedMetric = true
                            limitations.append(.missingEvidenceBoundary)
                            continue
                        }
                        guard let count = Int64(point.asInt), count >= 0,
                              let endNanos = UInt64(point.timeUnixNano), endNanos > startNanos,
                              let tokenTypeText = pointAttributes["type"],
                              let tokenType = ClaudeCodeTokenType(rawValue: tokenTypeText),
                              let model = pointAttributes["model"],
                              let rawAccount = pointAttributes["user.account_uuid"], UUID(uuidString: rawAccount) != nil,
                              let rawSession = pointAttributes["session.id"], UUID(uuidString: rawSession) != nil else {
                            foundUnsupportedMetric = true
                            continue
                        }
                        let intervalStart = Date(timeIntervalSince1970: Double(startNanos) / 1_000_000_000)
                        let intervalEnd = Date(timeIntervalSince1970: Double(endNanos) / 1_000_000_000)
                        guard intervalStart.timeIntervalSince1970.isFinite, intervalEnd.timeIntervalSince1970.isFinite else {
                            foundUnsupportedMetric = true
                            continue
                        }
                        let accountIdentity = keyedDigest(rawAccount, key: identityKey)
                        let sessionIdentity = keyedDigest(rawSession, key: identityKey)
                        let identityMaterial = "\(accountIdentity):\(sessionIdentity):\(startNanosText):\(point.timeUnixNano):\(tokenType.rawValue):\(count):\(model)"
                        guard let normalized = try? ClaudeCodeOTLPEvidence.validated(
                            identity: keyedDigest(identityMaterial, key: identityKey),
                            accountIdentity: accountIdentity,
                            sessionIdentity: sessionIdentity,
                            intervalStart: intervalStart,
                            intervalEnd: intervalEnd,
                            model: model,
                            tokenType: tokenType,
                            tokenCount: count,
                            sourceVersion: sourceVersion,
                            adapterVersion: adapterVersion
                        ) else {
                            foundUnsupportedMetric = true
                            continue
                        }
                        evidence.append(normalized)
                    }
                }
            }
        }

        let status: ClaudeCodeOTLPSourceStatus
        if foundUnsupportedVersion {
            status = .unsupportedVersion
            evidence = []
        } else if foundUnsupportedMetric {
            status = .unsupportedMetric
            evidence = []
        } else if !evidence.isEmpty {
            status = .supported
        } else if foundClaudeMetric {
            status = .unsupportedMetric
        } else {
            status = .noClaudeCodeMetric
        }
        return result(status, evidence: evidence, limitations: limitations)
    }

    private static func result(
        _ status: ClaudeCodeOTLPSourceStatus,
        evidence: [ClaudeCodeOTLPEvidence] = [],
        limitations: [ClaudeEvidenceLimitation] = []
    ) -> ClaudeCodeOTLPScanResult {
        ClaudeCodeOTLPScanResult(
            sourceStatus: status,
            evidence: evidence,
            omittedFieldCategories: [.contentBearing, .accountLabel, .privatePath, .arbitraryAttribute],
            limitations: Array(Set(limitations)).sorted { $0.rawValue < $1.rawValue },
            lastVerified: lastVerified
        )
    }

    private static func attributes(_ values: [OTLPAttribute]) -> [String: String] {
        Dictionary(values.compactMap { value in
            guard let text = value.value.stringValue else { return nil }
            return (value.key, text)
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func keyedDigest(_ value: String, key: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        } == true
    }
}

private struct ExportMetricsRequest: Decodable {
    let resourceMetrics: [ResourceMetrics]
}

private struct ResourceMetrics: Decodable {
    let scopeMetrics: [ScopeMetrics]
}

private struct ScopeMetrics: Decodable {
    let metrics: [OTLPMetric]
}

private struct OTLPMetric: Decodable {
    let name: String
    let sum: OTLPSum?
}

private struct OTLPSum: Decodable {
    let aggregationTemporality: Int
    let isMonotonic: Bool
    let dataPoints: [OTLPNumberDataPoint]
}

private struct OTLPNumberDataPoint: Decodable {
    let attributes: [OTLPAttribute]
    let startTimeUnixNano: String?
    let timeUnixNano: String
    let asInt: String
}

private struct OTLPAttribute: Decodable {
    let key: String
    let value: OTLPValue
}

private struct OTLPValue: Decodable {
    let stringValue: String?
}
