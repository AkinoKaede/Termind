import Foundation
import SwiftData

extension HostLibraryModel {
    convenience init(
        modelContext: ModelContext,
        secrets: any SecretStoring = KeychainSecretStore()
    ) {
        self.init(
            persistence: HostPersistence(context: modelContext),
            secrets: secrets
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

extension SkillLibraryModel {
    convenience init(
        modelContext: ModelContext,
        seedDefaults: UserDefaults = .standard
    ) {
        self.init(
            persistence: SkillPersistence(context: modelContext),
            seedDefaults: seedDefaults
        )
    }
}
