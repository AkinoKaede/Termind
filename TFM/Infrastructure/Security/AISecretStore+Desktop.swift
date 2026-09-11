import SwiftData
import TermindPersistence
import TermindRemoteInfrastructure

extension AISecretStore {
    convenience init(context: ModelContext) { self.init(context: context, keychain: KeychainSecretStore()) }
}
