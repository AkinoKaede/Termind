// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication
import TermindDomain

extension RemoteSessionBackendRegistry {
    public nonisolated static var live: Self {
        Self(
            Dictionary(
                uniqueKeysWithValues: RemoteMultiplexerRegistry.dialects.map {
                    dialect -> (SessionPersistenceBackendID, Factory) in
                    (dialect.id, { execute in dialect.backend(execute: execute) })
                }))
    }
}
