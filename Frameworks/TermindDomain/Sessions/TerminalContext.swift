import Foundation

/// Runtime identity, deliberately unrelated to session ownership or recovery.
public nonisolated struct TerminalContextIdentity: Hashable, Sendable {
    public let backend: String
    public let server: String
    public let session: String
    public let pane: String
    public let shellInstance: String

    public init(backend: String, server: String, session: String, pane: String, shellInstance: String) {
        self.backend = backend
        self.server = server
        self.session = session
        self.pane = pane
        self.shellInstance = shellInstance
    }
}

public nonisolated struct TerminalContextCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let directory = Self(rawValue: 1 << 0)
    public static let commandLifecycle = Self(rawValue: 1 << 1)
    public static let readDraft = Self(rawValue: 1 << 2)
    public static let replaceDraft = Self(rawValue: 1 << 3)
}

public nonisolated enum TerminalDirectorySource: Sendable, Equatable {
    case shell, nativePane, process
}

public nonisolated enum TerminalRuntimeIssue: Sendable, Equatable {
    case clientUnbound, paneAmbiguous, directoryUnavailable, shellIntegrationUnavailable
    case unsupportedVersion, nestedMultiplexer, inspectionUnavailable
}

public nonisolated struct TerminalShellContext: Sendable, Equatable {
    public let identity: TerminalContextIdentity
    public var shell: String
    /// Last cwd reported by this shell instance, independent of foreground/input readiness.
    public var directory: String?
    public var directorySource: TerminalDirectorySource?
    public var home: String?
    public var historyPath: String?
    public var promptReady: Bool
    public var sequence: UInt64
    public var capabilities: TerminalContextCapabilities

    /// Nil means unverified; an empty path explicitly disables file-backed history.
    public var historySource: ShellHistorySource? {
        guard let shell = ShellHistorySource.Shell(rawValue: shell),
            let historyPath, historyPath.isEmpty || historyPath.hasPrefix("/"),
            !historyPath.contains("\0")
        else { return nil }
        return .init(shell: shell, path: historyPath)
    }

    public init(
        identity: TerminalContextIdentity, shell: String, directory: String?, home: String?,
        promptReady: Bool, sequence: UInt64, capabilities: TerminalContextCapabilities, historyPath: String? = nil,
        directorySource: TerminalDirectorySource? = .shell
    ) {
        self.identity = identity
        self.shell = shell
        self.directory = directory
        self.directorySource = directory == nil ? nil : directorySource
        self.home = home
        self.historyPath = historyPath
        self.promptReady = promptReady
        self.sequence = sequence
        self.capabilities = capabilities
    }
}

public nonisolated struct TerminalContextEvent: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case commandStarted(String)
        case commandFinished(Int32, duration: TimeInterval?)
        case promptReady
        case directory(String)
        case draft(request: String, value: String)
    }
    public let context: TerminalContextIdentity
    public let sequence: UInt64
    public let payload: Payload

    public init(context: TerminalContextIdentity, sequence: UInt64, payload: Payload) {
        self.context = context
        self.sequence = sequence
        self.payload = payload
    }
}

public nonisolated struct TerminalRuntimeUpdate: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case ordinary, multiplexer, unknown, unavailable
    }
    public var status: Status
    public var clientIdentity: String?
    public var active: TerminalContextIdentity?
    public var contexts: [TerminalShellContext]
    public var events: [TerminalContextEvent]
    public var backend: SessionPersistenceBackendID?
    public var issue: TerminalRuntimeIssue?

    public init(
        status: Status, clientIdentity: String? = nil, active: TerminalContextIdentity? = nil,
        contexts: [TerminalShellContext] = [], events: [TerminalContextEvent] = [],
        backend: SessionPersistenceBackendID? = nil, issue: TerminalRuntimeIssue? = nil
    ) {
        self.status = status
        self.clientIdentity = clientIdentity
        self.active = active
        self.contexts = contexts
        self.events = events
        self.backend = backend
        self.issue = issue
    }
}
