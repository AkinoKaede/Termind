// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Execution-only payload. Secrets are never part of the observable import preview.
public nonisolated struct SSHImportBatch: Sendable {
    public var hosts: [Host] = []
    public var identities: [Identity] = []
    public var keys: [SSHKeyRef] = []
    public var knownHosts: [KnownHostEntry] = []
    public var credentials: [UUID: StoredSSHKeyCredential] = [:]
    public init(
        hosts: [Host] = [], identities: [Identity] = [], keys: [SSHKeyRef] = [], knownHosts: [KnownHostEntry] = [],
        credentials: [UUID: StoredSSHKeyCredential] = [:]
    ) {
        self.hosts = hosts
        self.identities = identities
        self.keys = keys
        self.knownHosts = knownHosts
        self.credentials = credentials
    }

}
