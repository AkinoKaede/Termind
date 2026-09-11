import TermindInfrastructure
import TermindRemoteInfrastructure

extension KeychainSecretStore {
    init() { self.init(accessGroup: ApplicationIdentity.keychainAccessGroup) }
}
