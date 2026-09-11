import SwiftData
import TermindPersistence

typealias AISecretStore = SharedAISecretStore

extension AISecretStore {
    convenience init(context: ModelContext) { self.init(context: context, keychain: KeychainSecretStore()) }
}
