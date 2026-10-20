// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

nonisolated struct ResumableTerminalStartup {
    let plan: SSHPTYStartupPlan?

    static func prepare(
        restoring: Bool, preparation: SSHPTYChannel.StartupPreparation?,
        execute: @escaping RemoteSessionCommandExecutor
    ) async throws -> Self {
        // A restored transport already owns its remote PTY, including any attached tmux client.
        guard !restoring else { return Self(plan: nil) }
        return Self(plan: try await preparation?(execute))
    }

    var moshArguments: String {
        get throws {
            guard let plan else { return "" }
            return " -- /bin/sh -c \(try RemoteTmuxCommands.quote(plan.command))"
        }
    }

    var eternalInput: Data? {
        get throws {
            guard let plan else { return nil }
            return Data((" exec /bin/sh -c \(try RemoteTmuxCommands.quote(plan.command))\r").utf8)
        }
    }
}
