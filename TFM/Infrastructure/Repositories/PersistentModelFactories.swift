// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindApplication
import TermindPersistence
import TermindRemoteInfrastructure

extension HostLibraryModel {
    convenience init(
        modelContext: ModelContext,
        secrets: any SecretStoring = KeychainSecretStore(),
        localDefaults: UserDefaults? = nil
    ) {
        self.init(
            persistence: HostPersistence(context: modelContext),
            secrets: secrets,
            localDefaults: localDefaults
        )
    }
}

extension AIConfigurationModel {
    convenience init(
        modelContext: ModelContext,
        secrets: any SecretStoring = KeychainSecretStore(),
        persistsSecrets: Bool = true,
        permissionDefaults: UserDefaults = .standard
    ) {
        self.init(
            persistence: AIPersistence(context: modelContext),
            secrets: secrets,
            persistsSecrets: persistsSecrets,
            permissionDefaults: permissionDefaults
        )
    }
}
