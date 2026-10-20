// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

extension KnownHostEntry {
    public var presentationTitle: String {
        isHashed ? String(localized: "Hashed Address") : displayAddress
    }
}
