// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A command in one live terminal session. File records may have no execution timestamp.
public nonisolated struct CommandHistoryEntry: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var sessionID: UUID
    public var command: String
    public var executedAt: Date?
    /// `nil` means the shell never reported a completion event, including rows
    /// written by versions that predate command lifecycle reporting.
    public var exitStatus: Int32?
    public var duration: TimeInterval?
    public init(
        id: UUID = UUID(), sessionID: UUID, command: String, executedAt: Date? = nil, exitStatus: Int32? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.command = command
        self.executedAt = executedAt
        self.exitStatus = exitStatus
        self.duration = duration
    }

    /// Converts an explicit shell line continuation into the single separator
    /// History needs for copying and replay. Real, unescaped line breaks stay
    /// intact because they may separate commands or belong to quoted content.
    public static func normalizingLineContinuations(in command: String) -> String {
        let input = Array(command.unicodeScalars)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            guard input[index].value == 0x5C else {
                output.append(input[index])
                index += 1
                continue
            }

            let lineBreakLength: Int
            if index + 1 < input.count, input[index + 1].value == 0x0A {
                lineBreakLength = 1
            } else if index + 2 < input.count, input[index + 1].value == 0x0D,
                input[index + 2].value == 0x0A
            {
                lineBreakLength = 2
            } else {
                output.append(input[index])
                index += 1
                continue
            }

            let precedingBackslashes = output.reversed().prefix { $0.value == 0x5C }.count
            guard precedingBackslashes.isMultiple(of: 2) else {
                output.append(input[index])
                index += 1
                continue
            }

            if precedingBackslashes == 0 {
                while output.last?.value == 0x20 || output.last?.value == 0x09 {
                    output.removeLast()
                }
            }
            index += 1 + lineBreakLength
            while index < input.count, input[index].value == 0x20 || input[index].value == 0x09 {
                index += 1
            }
            if !output.isEmpty, index < input.count { output.append(" ") }
        }

        return String(String.UnicodeScalarView(output))
    }

}
