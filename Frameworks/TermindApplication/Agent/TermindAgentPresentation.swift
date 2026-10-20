// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
    public static let command = Self("command")
    public static let commandOutput = Self("commandOutput")
    public static let hosts = Self("hosts")
    public static let metrics = Self("metrics")
    public static let remoteCommand = Self("remoteCommand")
    public static let remoteFile = Self("remoteFile")
    public static let remoteDirectory = Self("remoteDirectory")
    public static let sshCommand = Self("sshCommand")
    public static let suggestion = Self("suggestion")
}

nonisolated extension AgentToolDescriptor.Presentation.ActionKind {
    public static let provide = Self("provide")
    public static let cancel = Self("cancel")
}

nonisolated extension AgentToolDescriptor.Presentation.PhaseKind {
    public static let sshPreparingCommand = Self("sshPreparingCommand")
    public static let sshWaitingForCommand = Self("sshWaitingForCommand")
    public static let sshWaitingForAuthentication = Self("sshWaitingForAuthentication")
    public static let sshConnecting = Self("sshConnecting")
    public static let sshRunningCommand = Self("sshRunningCommand")
    public static let sshCompletedCommand = Self("sshCompletedCommand")
    public static let sshDeniedCommand = Self("sshDeniedCommand")
    public static let sshFailedCommand = Self("sshFailedCommand")
    public static let sshInterruptedCommand = Self("sshInterruptedCommand")
}
