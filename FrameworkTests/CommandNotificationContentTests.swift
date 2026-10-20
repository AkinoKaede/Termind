// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindPresentation
import Testing

@Suite
struct CommandNotificationContentTests {
    @Test(arguments: [0, 1, nil] as [Int?], ["npm\nrun\tbuild", nil, " \n\t"] as [String?])
    func bodyIsOneLineWithTheActualResult(exitCode: Int?, command: String?) {
        let completion = TerminalCommandCompletion(command: command, exitCode: exitCode, duration: 12)
        let body = CommandNotificationContent.body(completion)

        #expect(!body.isEmpty)
        #expect(!body.contains("\n"))
        if command == "npm\nrun\tbuild" {
            #expect(body.contains("npm run build"))
        }
        if let exitCode, exitCode != 0 {
            #expect(body.contains("\(exitCode)"))
        }
    }

    @Test func longCommandKeepsTheFailureCodeAfterTheEllipsis() {
        let completion = TerminalCommandCompletion(
            command: String(repeating: "字", count: 170), exitCode: 127, duration: 12)
        let body = CommandNotificationContent.body(completion)

        #expect(body.contains("…"))
        #expect(body.contains("127"))
    }
}
