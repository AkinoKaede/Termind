// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindRemoteInfrastructure

extension SSHImportReader {
    init() {
        self.init(
            username: NSUserName(),
            home: URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()))
    }
}
