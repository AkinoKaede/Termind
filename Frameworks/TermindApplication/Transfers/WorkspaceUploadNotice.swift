// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum WorkspaceUploadNotice: Equatable, Sendable {
    case preparing(String)
    case queued(Int, String)
    case rejected(String)
}

public nonisolated enum TerminalUploadAvailability {
    public static func problem(
        isConnected: Bool,
        hasTransferConfiguration: Bool,
        isWorkingDirectoryPending: Bool,
        workingDirectory: String?
    ) -> String? {
        guard isConnected, hasTransferConfiguration else {
            return String(localized: "The SSH session is not ready for file transfer.")
        }
        guard !isWorkingDirectoryPending,
            let workingDirectory,
            !workingDirectory.isEmpty
        else {
            return String(localized: "Wait for the shell prompt to report its current directory.")
        }
        return nil
    }
}
