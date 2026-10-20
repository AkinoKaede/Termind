// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindDomain

@MainActor
public protocol SSHPreferencesPersisting: AnyObject {
    func loadSSH() throws -> SSHPreferences
    func saveSSH(_ value: SSHPreferences) throws
}
