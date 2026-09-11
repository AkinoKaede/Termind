import TermindInfrastructure
import TermindRemoteInfrastructure

typealias KeychainSecretError = TermindRemoteInfrastructure.KeychainSecretError
typealias KeychainSecretStore = TermindRemoteInfrastructure.KeychainSecretStore

extension KeychainSecretStore {
    init() { self.init(accessGroup: ApplicationIdentity.keychainAccessGroup) }
}
