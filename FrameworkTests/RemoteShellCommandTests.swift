// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import Testing

@Suite
struct RemoteShellCommandTests {
    @Test(arguments: [
        ("/", "/"),
        ("/srv/app-1.0_test", "/srv/app-1.0_test"),
        ("/srv/中文目录", "/srv/中文目录"),
        ("/srv/my files", #"/srv/my\ files"#),
        ("/srv/it's live", #"/srv/it\'s\ live"#),
        (#"/srv/"quoted"\file"#, #"/srv/\"quoted\"\\file"#),
        (#"/srv/$HOME/$(pwd)/`pwd`"#, #"/srv/\$HOME/\$\(pwd\)/\`pwd\`"#),
        ("/srv/*?[abc]{a,b}!~#;&|<>()^=", "/srv/\\*\\?\\[abc\\]\\{a\\,b\\}\\!\\~\\#\\;\\&\\|\\<\\>\\(\\)\\^\\="),
        (" /srv/with trailing space ", #"\ /srv/with\ trailing\ space\ "#),
        ("/srv/a\tb", "/srv/a\\\tb"),
        ("", "''"),
        ("/srv/line\nbreak", "'/srv/line\nbreak'"),
        ("/srv/it's\r\nlive", "'/srv/it'\"'\"'s\r\nlive'"),
    ])
    func argumentsPreferBackslashesAndPreserveEveryCharacter(_ value: String, _ expected: String) {
        #expect(RemoteShellCommand.escapeArgument(value) == expected)
    }

    #if os(macOS)
        @Test
        func spaceSeparatedPathsRoundTripThroughPOSIXShellAsDistinctLiteralArguments() throws {
            let paths = [
                "/srv/中文目录", "/srv/my files", "/srv/it's live", #"/srv/"quoted"\file"#,
                #"/srv/$HOME/$(printf substituted)/`printf substituted`"#,
                "/srv/*?[abc]{a,b}!~#;&|<>()^=", "/srv/line\nbreak", "/srv/it's\r\nlive",
                "/srv/a\tb", " /srv/trailing ", "",
            ]
            let arguments = paths.map(RemoteShellCommand.escapeArgument).joined(separator: " ")
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "set -- \(arguments); printf '%s\\000' \"$@\""]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(data == Data(paths.map { $0 + "\0" }.joined().utf8))
        }
    #endif

    @Test
    func directoryChangesQuoteRemotePaths() {
        #expect(
            RemoteShellCommand.changeDirectory(to: "/srv/it's live")
                == "cd '/srv/it'\"'\"'s live'"
        )
        #expect(RemoteShellCommand.changeDirectory(to: "") == nil)
    }
}
