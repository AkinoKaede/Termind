// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindRemoteInfrastructure

extension KeychainSecretStore {
    init() { self.init(accessGroup: ApplicationIdentity.keychainAccessGroup) }
}
