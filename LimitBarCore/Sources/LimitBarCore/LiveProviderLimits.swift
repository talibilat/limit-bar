import Foundation
import Security

// Live provider limits, read the same way T3 Code reads them:
// Codex through `codex app-server` (account/rateLimits/read), Cursor through its
// dashboard API using the Cursor login in Keychain, and Antigravity through
// Google's quota API using the token file Antigravity writes.

public struct LiveLimitWindow: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
    }
}

public struct LiveLimitGroup: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let windows: [LiveLimitWindow]

    public init(id: String, title: String?, windows: [LiveLimitWindow]) {
        self.id = id
        self.title = title
        self.windows = windows
    }
}

public enum LiveProvider: String, CaseIterable, Sendable {
    case codex, cursor, antigravity

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        }
    }
}

public enum LiveLimitsState: Equatable, Sendable {
    case loading
    case loaded(groups: [LiveLimitGroup], plan: String?, fetchedAt: Date)
    case unavailable(String)
}

public enum LiveLimitsError: Error, Equatable, Sendable {
    case message(String)

    public var text: String {
        switch self { case .message(let text): text }
    }
}

public enum LiveProviderLimits {
    // MARK: Codex

    public static func parseCodex(_ result: [String: Any]) -> (groups: [LiveLimitGroup], plan: String?)? {
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        guard let snapshot = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) else {
            return nil
        }
        if let limitID = snapshot["limitId"] as? String, limitID != "codex" { return nil }
        let plan = snapshot["planType"] as? String
        let monthlyPlan = plan == "free" || plan == "go"
        var windows: [LiveLimitWindow] = []
        for (id, fallback) in [("primary", monthlyPlan ? 43_200.0 : 300.0), ("secondary", 10_080.0)] {
            guard let raw = snapshot[id] as? [String: Any],
                  let used = (raw["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
            let minutes = (raw["windowDurationMins"] as? NSNumber)?.doubleValue ?? fallback
            let label = minutes >= 43_200 ? "Monthly" : minutes >= 10_080 ? "Weekly" : "Session (5 hours)"
            let reset = (raw["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(LiveLimitWindow(id: id, label: label, usedPercent: used, resetsAt: reset))
        }
        if let individual = snapshot["individualLimit"] as? [String: Any],
           let remaining = (individual["remainingPercent"] as? NSNumber)?.doubleValue, remaining.isFinite {
            let reset = (individual["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(LiveLimitWindow(id: "individual", label: "Monthly credit limit", usedPercent: 100 - remaining, resetsAt: reset))
        }
        guard !windows.isEmpty else { return nil }
        return ([LiveLimitGroup(id: "codex", title: nil, windows: windows)], plan)
    }

    public static func fetchCodex(binary: URL? = nil, timeout: TimeInterval = 20) async throws -> (groups: [LiveLimitGroup], plan: String?) {
        let executable = binary ?? locateCodex()
        guard let executable else { throw LiveLimitsError.message("Codex is not installed. Install the Codex CLI, then log in.") }
        let parsed = try await Task.detached(priority: .utility) { () throws -> (groups: [LiveLimitGroup], plan: String?) in
            let result = try runCodexAppServer(executable: executable, timeout: timeout)
            guard let parsed = parseCodex(result) else {
                throw LiveLimitsError.message("Codex did not return usable limits.")
            }
            return parsed
        }.value
        return parsed
    }

    private static func locateCodex() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.bun/bin/codex", "\(home)/.npm-global/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static func runCodexAppServer(executable: URL, timeout: TimeInterval) throws -> [String: Any] {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw LiveLimitsError.message("Codex could not be started to read limits.")
        }
        defer {
            if process.isRunning { process.terminate() }
        }
        func send(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        func response(id: Int) throws -> [String: Any] {
            while Date() < deadline {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       (object["id"] as? Int) == id {
                        return object
                    }
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            throw LiveLimitsError.message("Codex did not answer the limits request.")
        }
        // A watchdog stops a hung process so the blocking read returns.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "limitbar", "title": "limitbar", "version": "1"],
            "capabilities": ["experimentalApi": true]
        ]])
        _ = try response(id: 1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
        let reply = try response(id: 2)
        if reply["error"] != nil {
            throw LiveLimitsError.message("Codex could not read limits. Log in to Codex again.")
        }
        guard let result = reply["result"] as? [String: Any] else {
            throw LiveLimitsError.message("Codex did not return usable limits.")
        }
        return result
    }

    // MARK: Cursor

    public static func parseCursor(_ object: [String: Any]) -> [LiveLimitGroup]? {
        guard let usage = object["planUsage"] as? [String: Any] else { return nil }
        var reset: Date?
        if let value = object["billingCycleEnd"], let millis = Double("\(value)"), millis > 0 {
            reset = Date(timeIntervalSince1970: millis / 1000)
        }
        let rows = [("totalPercentUsed", "Overall"), ("autoPercentUsed", "Cursor models"), ("apiPercentUsed", "Other models")]
        let windows = rows.compactMap { id, label -> LiveLimitWindow? in
            guard let used = (usage[id] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
            return LiveLimitWindow(id: id, label: label, usedPercent: used, resetsAt: reset)
        }
        return windows.isEmpty ? nil : [LiveLimitGroup(id: "cursor", title: nil, windows: windows)]
    }

    public static func fetchCursor() async throws -> [LiveLimitGroup] {
        guard let token = cursorToken() else {
            throw LiveLimitsError.message("Log in to Cursor, then allow LimitBar to read the Keychain item.")
        }
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("cli", forHTTPHeaderField: "x-cursor-client-type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = parseCursor(object) else {
            throw LiveLimitsError.message("Cursor could not read usage limits. Log in to Cursor again.")
        }
        return groups
    }

    private static func cursorToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["CURSOR_AUTH_TOKEN"], !env.isEmpty { return env }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cursor-access-token",
            kSecAttrAccount as String: "cursor-user",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    // MARK: Antigravity

    public static func parseAntigravity(_ object: [String: Any]) -> [LiveLimitGroup]? {
        let iso = ISO8601DateFormatter()
        var groups: [LiveLimitGroup] = []
        let rawGroups = (object["groups"] as? [[String: Any]]) ?? [["buckets": object["buckets"] as Any]]
        for (index, group) in rawGroups.enumerated() {
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            var windows: [LiveLimitWindow] = []
            for bucket in buckets {
                if bucket["disabled"] as? Bool == true { continue }
                guard let id = bucket["bucketId"] as? String,
                      let remaining = (bucket["remainingFraction"] as? NSNumber)?.doubleValue, remaining.isFinite else { continue }
                let window = bucket["window"] as? String
                let label = window == "weekly" ? "Weekly" : window == "5h" ? "Session (5 hours)" : (bucket["displayName"] as? String ?? "Quota")
                let minutes: Double? = window == "weekly" ? 10_080 : window == "5h" ? 300 : nil
                var reset = (bucket["resetTime"] as? String).flatMap { iso.date(from: $0) }
                // An untouched bucket reports a rolling full-window reset, so hide it.
                if let date = reset, let minutes, remaining == 1, abs(date.timeIntervalSinceNow - minutes * 60) <= 60 { reset = nil }
                windows.append(LiveLimitWindow(id: id, label: label, usedPercent: (1 - min(1, max(0, remaining))) * 100, resetsAt: reset))
            }
            windows.sort { ($0.label == "Session (5 hours)" ? 0 : 1) < ($1.label == "Session (5 hours)" ? 0 : 1) }
            if !windows.isEmpty {
                groups.append(LiveLimitGroup(id: "ag-\(index)", title: group["displayName"] as? String, windows: windows))
            }
        }
        return groups.isEmpty ? nil : groups
    }

    public static func fetchAntigravity() async throws -> [LiveLimitGroup] {
        guard let tokenFile = antigravityTokenFile(),
              let token = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tokenFile))) as? [String: Any],
              let clientID = token["client_id"] as? String,
              let clientSecret = token["client_secret"] as? String,
              let refresh = token["refresh_token"] as? String else {
            throw LiveLimitsError.message("Sign in to Antigravity with Google to see its limits.")
        }
        var refreshRequest = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 15)
        refreshRequest.httpMethod = "POST"
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        refreshRequest.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        refreshRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (tokenData, tokenResponse) = try await URLSession.shared.data(for: refreshRequest)
        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
              let access = ((try? JSONSerialization.jsonObject(with: tokenData)) as? [String: Any])?["access_token"] as? String else {
            throw LiveLimitsError.message("Antigravity login expired. Sign in with Google again.")
        }
        let body: [String: Any] = (token["project_id"] as? String).map { ["project": $0] } ?? [:]
        var best: [String: LiveLimitWindow] = [:]
        var layout: [LiveLimitGroup] = []
        for endpoint in ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"] {
            var request = URLRequest(url: URL(string: "\(endpoint)/v1internal:retrieveUserQuotaSummary")!, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let groups = parseAntigravity(object) else { continue }
            if layout.isEmpty { layout = groups }
            for window in groups.flatMap(\.windows) where window.usedPercent >= (best[window.id]?.usedPercent ?? -1) {
                best[window.id] = window
            }
        }
        guard !layout.isEmpty else {
            throw LiveLimitsError.message("Antigravity did not return usable quota information.")
        }
        return layout.map { group in
            LiveLimitGroup(id: group.id, title: group.title, windows: group.windows.map { best[$0.id] ?? $0 })
        }
    }

    private static func antigravityTokenFile() -> URL? {
        let providers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata/providers/antigravity")
        let directories = (try? FileManager.default.contentsOfDirectory(at: providers, includingPropertiesForKeys: nil)) ?? []
        let files = directories
            .map { $0.appendingPathComponent("antigravity-acp/acp_token.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return files.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    // MARK: Entry point

    public static func fetch(_ provider: LiveProvider, now: Date = Date()) async -> LiveLimitsState {
        do {
            switch provider {
            case .codex:
                let result = try await fetchCodex()
                return .loaded(groups: result.groups, plan: result.plan.map { $0.capitalized }, fetchedAt: now)
            case .cursor:
                return .loaded(groups: try await fetchCursor(), plan: nil, fetchedAt: now)
            case .antigravity:
                return .loaded(groups: try await fetchAntigravity(), plan: nil, fetchedAt: now)
            }
        } catch let error as LiveLimitsError {
            return .unavailable(error.text)
        } catch {
            return .unavailable("\(provider.displayName) could not be reached. Check your connection and try again.")
        }
    }
}
