import AgentKit
import Foundation

/// The card vocabulary Termind's own tools need on top of the runtime's.
///
/// `AgentToolDescriptor.Presentation`'s semantic kinds are open for exactly this
/// reason: the runtime ships the nouns its built-in tools use, and an app that
/// reaches somewhere else names that somewhere itself. Everything here is about
/// hosts — commands, remote files, and the phases an SSH connection goes through
/// that "running" alone does not describe.
///
/// Raw values are the strings these were persisted with while they were enum
/// cases, so cards written by earlier releases still decode and still render.
nonisolated extension AgentToolDescriptor.Presentation.ActivityKind {
    static let command = Self("command")
    static let hosts = Self("hosts")
    static let metrics = Self("metrics")
    static let remoteCommand = Self("remoteCommand")
    static let remoteFile = Self("remoteFile")
    static let sshCommand = Self("sshCommand")
}

nonisolated extension AgentToolDescriptor.Presentation.PhaseKind {
    static let sshPreparingCommand = Self("sshPreparingCommand")
    static let sshWaitingForCommand = Self("sshWaitingForCommand")
    static let sshWaitingForAuthentication = Self("sshWaitingForAuthentication")
    static let sshConnecting = Self("sshConnecting")
    static let sshRunningCommand = Self("sshRunningCommand")
    static let sshCompletedCommand = Self("sshCompletedCommand")
    static let sshDeniedCommand = Self("sshDeniedCommand")
    static let sshFailedCommand = Self("sshFailedCommand")
    static let sshInterruptedCommand = Self("sshInterruptedCommand")
}
