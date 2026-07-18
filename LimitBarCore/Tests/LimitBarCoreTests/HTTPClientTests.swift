import Foundation
import Testing
@testable import LimitBarCore

@Suite("HTTP client security")
struct HTTPClientTests {
    @Test("secure URL session configuration is ephemeral and bounded")
    func secureConfiguration() {
        let configuration = URLSessionHTTPClient.secureConfiguration()

        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 30)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
    }

    @Test("credentialed redirects require the same scheme host and effective port", arguments: [
        ("https://api.example.com/start", "https://api.example.com/next", true),
        ("https://api.example.com/start", "https://api.example.com:443/next", true),
        ("https://api.example.com/start", "http://api.example.com/next", false),
        ("https://api.example.com/start", "https://other.example.com/next", false),
        ("https://api.example.com/start", "https://api.example.com:444/next", false)
    ])
    func credentialedRedirects(from: String, to: String, expected: Bool) throws {
        var original = URLRequest(url: try #require(URL(string: from)))
        original.setValue("secret", forHTTPHeaderField: "x-api-key")
        let redirected = URLRequest(url: try #require(URL(string: to)))

        #expect(URLSessionRedirectPolicy.shouldFollow(from: original, to: redirected) == expected)
    }

    @Test("all credential header spellings are protected", arguments: ["Authorization", "Proxy-Authorization", "x-api-key", "api-key"])
    func credentialHeadersAreProtected(header: String) throws {
        var original = URLRequest(url: try #require(URL(string: "https://api.example.com/start")))
        original.setValue("secret", forHTTPHeaderField: header)
        let redirected = URLRequest(url: try #require(URL(string: "https://attacker.example/next")))

        #expect(!URLSessionRedirectPolicy.shouldFollow(from: original, to: redirected))
    }

    @Test("default public requests may follow cross-origin redirects")
    func publicRedirectsAreAllowedByDefault() throws {
        let original = URLRequest(url: try #require(URL(string: "https://public.example/start")))
        let redirected = URLRequest(url: try #require(URL(string: "http://cdn.example/next")))

        #expect(URLSessionRedirectPolicy.shouldFollow(from: original, to: redirected))
    }

    @Test("same-origin mode rejects cross-origin public redirects")
    func pinnedPublicRedirects() throws {
        let original = URLRequest(url: try #require(URL(string: "https://status.openai.com/api/v2/summary.json")))
        let sameOrigin = URLRequest(url: try #require(URL(string: "https://status.openai.com/api/v2/summary.json?next=1")))
        let crossOrigin = URLRequest(url: try #require(URL(string: "https://example.com/status")))
        let downgrade = URLRequest(url: try #require(URL(string: "http://status.openai.com/status")))

        #expect(URLSessionRedirectPolicy.shouldFollow(from: original, to: sameOrigin, mode: .sameOrigin))
        #expect(!URLSessionRedirectPolicy.shouldFollow(from: original, to: crossOrigin, mode: .sameOrigin))
        #expect(!URLSessionRedirectPolicy.shouldFollow(from: original, to: downgrade, mode: .sameOrigin))
    }

    @Test("releasing the client invalidates its owned URL session exactly once")
    func clientInvalidatesOwnedSession() {
        let spy = InvalidationSpy()
        var client: URLSessionHTTPClient? = URLSessionHTTPClient(
            configuration: .ephemeral,
            onInvalidate: { session in
                spy.record()
                session.invalidateAndCancel()
            }
        )

        #expect(client != nil)
        #expect(spy.count == 0)
        client = nil
        #expect(spy.count == 1)
    }
}

private final class InvalidationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func record() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
