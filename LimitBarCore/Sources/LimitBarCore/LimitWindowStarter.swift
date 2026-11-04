import Foundation
import Observation

// Starts a fresh Claude Code or Codex limit window as soon as the previous one resets,
// by sending the smallest possible prompt through the tool's own CLI one minute after
// the 5-hour or weekly reset. It runs only while LimitBar is open.

public enum WindowStarterProduct: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

public struct LimitWindowResets: Equatable, Sendable {
    /// True when the provider reported a 5-hour window at all.
    public let hasSessionWindow: Bool
    /// Nil while a reported 5-hour window has not started yet.
    public let sessionResetsAt: Date?
    public let weeklyResetsAt: Date?

    public init(hasSessionWindow: Bool, sessionResetsAt: Date?, weeklyResetsAt: Date?) {
        self.hasSessionWindow = hasSessionWindow
        self.sessionResetsAt = sessionResetsAt
        self.weeklyResetsAt = weeklyResetsAt
    }
}

public enum WindowStartPlan: Equatable, Sendable {
    case sendNow
    case wait(until: Date)

    public static let delayAfterReset: TimeInterval = 60
    public static let minimumGap: TimeInterval = 10 * 60
    public static let recheckInterval: TimeInterval = 15 * 60

    public static func plan(resets: LimitWindowResets, lastSentAt: Date?, now: Date) -> WindowStartPlan {
        let plan = unthrottledPlan(resets: resets, lastSentAt: lastSentAt, now: now)
        if plan == .sendNow, let lastSentAt, now.timeIntervalSince(lastSentAt) < minimumGap {
            return .wait(until: lastSentAt.addingTimeInterval(minimumGap))
        }
        return plan
    }

    public static func pendingSendAt(resets: LimitWindowResets?, previous: Date?, lastSentAt: Date?) -> Date? {
        ([previous] + [resets?.sessionResetsAt, resets?.weeklyResetsAt]
            .map { $0?.addingTimeInterval(delayAfterReset) })
            .compactMap { $0 }
            .filter { $0 > (lastSentAt ?? .distantPast) }
            .min()
    }

    private static func unthrottledPlan(resets: LimitWindowResets, lastSentAt: Date?, now: Date) -> WindowStartPlan {
        if resets.hasSessionWindow && resets.sessionResetsAt == nil {
            return .sendNow
        }
        let targets = [resets.sessionResetsAt, resets.weeklyResetsAt]
            .compactMap { $0?.addingTimeInterval(delayAfterReset) }
        if targets.contains(where: { $0 <= now && (lastSentAt ?? .distantPast) < $0 }) {
            return .sendNow
        }
        if let next = targets.filter({ $0 > now }).min() {
            return .wait(until: next)
        }
        return .wait(until: now.addingTimeInterval(recheckInterval))
    }
}

public enum LimitWindowMessenger {
    public static let message = "."

    public static func arguments(for product: WindowStarterProduct) -> [String] {
        switch product {
        case .claudeCode:
            ["-p", message, "--model", "haiku", "--tools", ""]
        case .codex:
            ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", message]
        }
    }

    /// Runs the CLI in an empty temporary folder and reports whether it exited cleanly.
    public static func send(_ product: WindowStarterProduct, executable: URL, timeout: TimeInterval = 180) async -> Bool {
        await Task.detached(priority: .utility) {
            run(product, executable: executable, timeout: timeout)
        }.value
    }

    private static func run(_ product: WindowStarterProduct, executable: URL, timeout: TimeInterval) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limitbar-window-starter", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: product)
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPath = [
            executable.deletingLastPathComponent().path,
            executable.resolvingSymlinksInPath().deletingLastPathComponent().path,
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        environment["PATH"] = (searchPath + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}

@MainActor
@Observable
public final class LimitWindowStarter {
    public struct Status: Equatable, Sendable {
        public var nextAt: Date?
        public var lastSentAt: Date?
        public var lastAttemptAt: Date?
        public var lastSucceeded: Bool?
        public var isSending = false
        public var note: String?
    }

    public typealias ReadResets = @MainActor (WindowStarterProduct) async -> LimitWindowResets?
    public typealias Send = @MainActor (WindowStarterProduct) async -> Bool

    public private(set) var enabled: Set<WindowStarterProduct> = []
    public private(set) var statuses: [WindowStarterProduct: Status] = [:]

    private let defaults: UserDefaults
    private var readResets: ReadResets?
    private var send: Send?
    private var tasks: [WindowStarterProduct: Task<Void, Never>] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for product in WindowStarterProduct.allCases {
            if defaults.bool(forKey: Self.enabledKey(product)) {
                enabled.insert(product)
            }
            let lastSent = defaults.object(forKey: Self.lastSentKey(product)) as? Double
            statuses[product] = Status(lastSentAt: lastSent.map(Date.init(timeIntervalSince1970:)))
        }
    }

    public func isEnabled(_ product: WindowStarterProduct) -> Bool {
        enabled.contains(product)
    }

    public func status(_ product: WindowStarterProduct) -> Status {
        statuses[product] ?? Status()
    }

    public func start(readResets: @escaping ReadResets, send: @escaping Send) {
        self.readResets = readResets
        self.send = send
        for product in enabled where tasks[product] == nil {
            launch(product)
        }
    }

    public func setEnabled(_ isEnabled: Bool, for product: WindowStarterProduct) {
        defaults.set(isEnabled, forKey: Self.enabledKey(product))
        tasks[product]?.cancel()
        tasks[product] = nil
        if isEnabled {
            enabled.insert(product)
            if readResets != nil { launch(product) }
        } else {
            enabled.remove(product)
            statuses[product]?.nextAt = nil
            statuses[product]?.note = nil
            statuses[product]?.isSending = false
        }
    }

    private func launch(_ product: WindowStarterProduct) {
        tasks[product] = Task { [weak self] in
            await self?.run(product)
        }
    }

    private func run(_ product: WindowStarterProduct) async {
        while !Task.isCancelled {
            guard let readResets, let send else { return }
            let resets = await readResets(product)
            let now = Date()
            guard !Task.isCancelled else { return }
            let pendingKey = "limitbar.windowStarter.\(product.rawValue).pendingSendAt"
            let previous = (defaults.object(forKey: pendingKey) as? Double).map(Date.init(timeIntervalSince1970:))
            let pending = WindowStartPlan.pendingSendAt(
                resets: resets, previous: previous, lastSentAt: statuses[product]?.lastSentAt
            )
            defaults.set(pending?.timeIntervalSince1970, forKey: pendingKey)
            var plan: WindowStartPlan
            if let pending, pending <= now {
                // Keep a due reset even when the provider rolls forward or cannot be reached.
                plan = .sendNow
                statuses[product]?.note = nil
            } else if let resets {
                plan = WindowStartPlan.plan(resets: resets, lastSentAt: statuses[product]?.lastSentAt, now: now)
                statuses[product]?.note = nil
            } else {
                plan = .wait(until: now.addingTimeInterval(WindowStartPlan.recheckInterval))
                statuses[product]?.note = "Limits unavailable. Trying again soon."
            }

            if let pending, case let .wait(until) = plan {
                plan = .wait(until: min(pending, until))
            }
            if plan == .sendNow, let attempt = statuses[product]?.lastAttemptAt,
               now.timeIntervalSince(attempt) < WindowStartPlan.minimumGap {
                plan = .wait(until: attempt.addingTimeInterval(WindowStartPlan.minimumGap))
            }

            switch plan {
            case .sendNow:
                statuses[product]?.isSending = true
                statuses[product]?.nextAt = nil
                let succeeded = await send(product)
                let sentAt = Date()
                statuses[product]?.isSending = false
                statuses[product]?.lastAttemptAt = sentAt
                statuses[product]?.lastSucceeded = succeeded
                if succeeded {
                    statuses[product]?.lastSentAt = sentAt
                    defaults.set(sentAt.timeIntervalSince1970, forKey: Self.lastSentKey(product))
                    defaults.removeObject(forKey: pendingKey)
                }
                // Give the provider a moment to report the new window before reading again.
                try? await Task.sleep(for: .seconds(90))
            case let .wait(until):
                statuses[product]?.nextAt = until
                // Wake at least every 30 minutes so changed reset times are picked up.
                let interval = min(max(until.timeIntervalSinceNow, 5), 30 * 60)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private static func enabledKey(_ product: WindowStarterProduct) -> String {
        "limitbar.windowStarter.\(product.rawValue).enabled"
    }

    private static func lastSentKey(_ product: WindowStarterProduct) -> String {
        "limitbar.windowStarter.\(product.rawValue).lastSentAt"
    }
}
