// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated protocol SSHImportReading: Sendable {
    func scan(root: URL, knownHostsOnly: Bool, grants: [URL]) async throws -> [SSHImportItem]
    func unlock(id: UUID, name: String, passphrase: String) async throws -> [SSHImportItem]
    func credentials(for ids: Set<UUID>) async throws -> [UUID: StoredSSHKeyCredential]
    func discard() async
}
