import Foundation
import Observation
import TermindDomain

public nonisolated struct TerminalCommandCompletion: Equatable, Sendable {
    public var command: String?
    public var exitCode: Int?
    public var duration: TimeInterval

    public init(command: String? = nil, exitCode: Int?, duration: TimeInterval) {
        self.command = command
        self.exitCode = exitCode
        self.duration = duration
    }

    public var commandPreview: String? {
        guard let command else { return nil }
        let cleaned = command.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > 160 ? String(cleaned.prefix(159)) + "…" : cleaned
    }
}

/// Per-terminal state, independent of history and transient view mounting.
@MainActor @Observable
public final class TerminalCommandMonitor {
    public private(set) var unreadCompletionCount = 0
    public var hasUnreadCompletion: Bool { unreadCompletionCount > 0 }
    public var preferences: () -> NotificationPreferences = { .init() }
    public var isWorkspaceFocused: () -> Bool = { false }
    public var alert: (TerminalCommandCompletion, NotificationPreferences) -> Void = { _, _ in }
    private let now: () -> TimeInterval
    private var active = false
    private var usesShellIntegration = false
    private var running: (command: String, started: TimeInterval)?

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public func beginConnection() {
        active = true
        usesShellIntegration = false
        running = nil
    }

    public func endConnection() {
        active = false
        running = nil
        usesShellIntegration = false
    }

    public func markRead() { unreadCompletionCount = 0 }

    public func receiveShellEvent(_ event: SSHShellIntegrationEvent) {
        guard active else { return }
        switch event {
        case .available:
            usesShellIntegration = true
        case .commandStarted(let command):
            guard usesShellIntegration else { return }
            running = (command, now())
        case .commandFinished(let status, let reported):
            guard usesShellIntegration, let command = running else { return }
            running = nil
            let duration =
                reported.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                ?? max(0, now() - command.started)
            complete(.init(command: command.command, exitCode: Int(status), duration: duration))
        default: break
        }
    }

    public func receiveOSC133(exitCode: Int?, durationNanos: UInt64) {
        guard active, !usesShellIntegration else { return }
        complete(.init(exitCode: exitCode, duration: Double(durationNanos) / 1_000_000_000))
    }

    private func complete(_ completion: TerminalCommandCompletion) {
        let focused = isWorkspaceFocused()
        unreadCompletionCount = focused ? 0 : unreadCompletionCount + 1
        let settings = preferences()
        guard settings.allowsTerminal(duration: completion.duration, isFocused: focused) else { return }
        alert(completion, settings)
    }
}
