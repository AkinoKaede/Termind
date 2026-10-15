import Foundation

public nonisolated enum SSHShellIntegrationEvent: Sendable {
    case runtime(TerminalRuntimeUpdate)
    case available(shell: String, systemInfo: RemoteSystemInfo?, homeDirectory: String?)
    case systemInfo(RemoteSystemInfo)
    case homeResolutionUnavailable
    case promptReady
    case commandStarted(String)
    case commandFinished(Int32, duration: TimeInterval?)
    case draft(String)
}
