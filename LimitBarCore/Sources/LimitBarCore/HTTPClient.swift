import Foundation

public enum HTTPMethod: String, Equatable, Sendable {
    case get = "GET"
}

public struct HTTPRequest: Equatable, Sendable {
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?

    public init(url: URL, method: HTTPMethod, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

enum PaginationError: Error {
    case pageLimitExceeded
    case repeatedToken
    case missingToken
}

struct PaginationGuard {
    private let maximumPageCount: Int
    private var pageCount = 0
    private var seenTokens: Set<String> = []

    init(maximumPageCount: Int = 100) {
        self.maximumPageCount = maximumPageCount
    }

    mutating func registerRequest(token: String?) throws {
        guard pageCount < maximumPageCount else { throw PaginationError.pageLimitExceeded }
        if let token {
            guard seenTokens.insert(token).inserted else { throw PaginationError.repeatedToken }
        }
        pageCount += 1
    }

    func nextToken(hasMore: Bool?, token: String?) throws -> String? {
        guard hasMore == true else { return nil }
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw PaginationError.missingToken
        }
        return token
    }
}

public enum URLSessionRedirectPolicy {
    public enum Mode: Equatable, Sendable {
        case credentialAware
        case sameOrigin
    }

    private static let credentialHeaders = ["authorization", "proxy-authorization", "x-api-key", "api-key"]

    public static func shouldFollow(
        from original: URLRequest,
        to redirected: URLRequest,
        mode: Mode = .credentialAware
    ) -> Bool {
        if mode == .sameOrigin {
            guard let originalURL = original.url, let redirectedURL = redirected.url else { return false }
            return origin(of: originalURL) == origin(of: redirectedURL)
        }
        let hasCredentials = original.allHTTPHeaderFields?.keys.contains {
            credentialHeaders.contains($0.lowercased())
        } == true
        guard hasCredentials else { return true }
        guard let originalURL = original.url, let redirectedURL = redirected.url else { return false }
        return origin(of: originalURL) == origin(of: redirectedURL)
    }

    private static func origin(of url: URL) -> Origin? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        guard let port else { return nil }
        return Origin(scheme: scheme, host: host, port: port)
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }
}

public final class URLSessionHTTPClient: @unchecked Sendable, HTTPClient {
    private let sessionBox: OwnedURLSession

    public convenience init() {
        self.init(redirectPolicy: .credentialAware)
    }

    public init(redirectPolicy: URLSessionRedirectPolicy.Mode) {
        let session = URLSession(
            configuration: Self.secureConfiguration(),
            delegate: RedirectDelegate(mode: redirectPolicy),
            delegateQueue: nil
        )
        sessionBox = OwnedURLSession(session: session, invalidate: { $0.invalidateAndCancel() })
    }

    init(
        configuration: URLSessionConfiguration,
        delegate: URLSessionTaskDelegate = RedirectDelegate(),
        onInvalidate: @escaping @Sendable (URLSession) -> Void = { $0.invalidateAndCancel() }
    ) {
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        sessionBox = OwnedURLSession(session: session, invalidate: onInvalidate)
    }

    public static func secureConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await sessionBox.session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return HTTPResponse(statusCode: response.statusCode, data: data)
    }
}

private final class OwnedURLSession: @unchecked Sendable {
    let session: URLSession
    private let invalidate: @Sendable (URLSession) -> Void

    init(session: URLSession, invalidate: @escaping @Sendable (URLSession) -> Void) {
        self.session = session
        self.invalidate = invalidate
    }

    deinit {
        invalidate(session)
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let mode: URLSessionRedirectPolicy.Mode

    init(mode: URLSessionRedirectPolicy.Mode = .credentialAware) {
        self.mode = mode
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest ?? task.currentRequest else {
            completionHandler(nil)
            return
        }
        completionHandler(URLSessionRedirectPolicy.shouldFollow(from: original, to: request, mode: mode) ? request : nil)
    }
}
