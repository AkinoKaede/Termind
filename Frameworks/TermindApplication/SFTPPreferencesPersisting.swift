// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindDomain

@MainActor
public protocol SFTPPreferencesPersisting: AnyObject {
    func loadSFTP() throws -> SFTPPreferences
    func saveSFTP(_ value: SFTPPreferences) throws
}
