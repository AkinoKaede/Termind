// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct SSHHostKeyIdentity: Hashable, Sendable {
    public var algorithm: SSHKeyAlgorithm
    public var fingerprint: String
    public init(algorithm: SSHKeyAlgorithm, fingerprint: String) {
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }

}
