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

public struct ClaudeCodeOTLPEvidence: Codable, Equatable, Sendable {
    public let identity: String
    public let accountIdentity: String
    public let sessionIdentity: String
    public let observedAt: Date
    public let model: String
    public let tokenType: ClaudeCodeTokenType
    public let tokenCount: Int64
    public let sourceVersion: String
    public let adapterVersion: String

    public init(
        identity: String,
        accountIdentity: String,
        sessionIdentity: String,
        observedAt: Date,
        model: String,
        tokenType: ClaudeCodeTokenType,
        tokenCount: Int64,
        sourceVersion: String,
        adapterVersion: String
    ) {
        self.identity = identity
        self.accountIdentity = accountIdentity
        self.sessionIdentity = sessionIdentity
        self.observedAt = observedAt
        self.model = model
        self.tokenType = tokenType
        self.tokenCount = tokenCount
        self.sourceVersion = sourceVersion
        self.adapterVersion = adapterVersion
    }
}

public struct ClaudeCodeOTLPScanResult: Equatable, Sendable {
    public let sourceStatus: ClaudeCodeOTLPSourceStatus
    public let evidence: [ClaudeCodeOTLPEvidence]
    public let omittedFieldCategories: [ClaudeCodeOmittedFieldCategory]
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
        var foundUnsupported = false
        var evidence: [ClaudeCodeOTLPEvidence] = []
        for resourceMetrics in request.resourceMetrics {
            let resource = attributes(resourceMetrics.resource?.attributes ?? [])
            guard let sourceVersion = resource["app.version"], sourceVersion == supportedSourceVersion else {
                foundUnsupported = true
                continue
            }
            guard let rawAccount = resource["user.account_uuid"], UUID(uuidString: rawAccount) != nil else {
                foundUnsupported = true
                continue
            }
            let accountIdentity = keyedDigest(rawAccount, key: identityKey)
            for scope in resourceMetrics.scopeMetrics {
                for metric in scope.metrics where metric.name == "claude_code.token.usage" {
                    foundClaudeMetric = true
                    guard let sum = metric.sum, sum.aggregationTemporality == 1, sum.isMonotonic else {
                        foundUnsupported = true
                        continue
                    }
                    for point in sum.dataPoints {
                        let pointAttributes = attributes(point.attributes)
                        guard let count = Int64(point.asInt), count >= 0,
                              let nanos = UInt64(point.timeUnixNano), nanos > 0,
                              let tokenTypeText = pointAttributes["type"],
                              let tokenType = ClaudeCodeTokenType(rawValue: tokenTypeText),
                              let model = pointAttributes["model"], validModel(model),
                              let rawSession = pointAttributes["session.id"], UUID(uuidString: rawSession) != nil else {
                            foundUnsupported = true
                            continue
                        }
                        let observedAt = Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
                        guard observedAt.timeIntervalSince1970.isFinite else {
                            foundUnsupported = true
                            continue
                        }
                        let sessionIdentity = keyedDigest(rawSession, key: identityKey)
                        let identityMaterial = "\(accountIdentity):\(sessionIdentity):\(point.timeUnixNano):\(tokenType.rawValue):\(count):\(model)"
                        evidence.append(ClaudeCodeOTLPEvidence(
                            identity: keyedDigest(identityMaterial, key: identityKey),
                            accountIdentity: accountIdentity,
                            sessionIdentity: sessionIdentity,
                            observedAt: observedAt,
                            model: model,
                            tokenType: tokenType,
                            tokenCount: count,
                            sourceVersion: sourceVersion,
                            adapterVersion: adapterVersion
                        ))
                    }
                }
            }
        }

        let status: ClaudeCodeOTLPSourceStatus
        if !evidence.isEmpty {
            status = foundUnsupported ? .unsupportedMetric : .supported
        } else if foundUnsupported {
            status = .unsupportedVersion
        } else if foundClaudeMetric {
            status = .unsupportedMetric
        } else {
            status = .noClaudeCodeMetric
        }
        return result(status, evidence: evidence)
    }

    private static func result(
        _ status: ClaudeCodeOTLPSourceStatus,
        evidence: [ClaudeCodeOTLPEvidence] = []
    ) -> ClaudeCodeOTLPScanResult {
        ClaudeCodeOTLPScanResult(
            sourceStatus: status,
            evidence: evidence,
            omittedFieldCategories: [.contentBearing, .accountLabel, .privatePath, .arbitraryAttribute],
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

    private static func validModel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.first?.isASCIIAlphaNumeric == true
            && value.allSatisfy { $0.isASCIIAlphaNumeric || $0 == "." || $0 == "_" || $0 == "-" }
            && !value.lowercased().hasPrefix("sk-")
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
    let resource: OTLPResource?
    let scopeMetrics: [ScopeMetrics]
}

private struct OTLPResource: Decodable {
    let attributes: [OTLPAttribute]
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
