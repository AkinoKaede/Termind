// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

extension SSHImportModel {
    convenience init(library: HostLibraryModel, reader: any SSHImportReading) {
        self.init(library: library, reader: reader, defaultUsername: NSUserName())
    }
}
