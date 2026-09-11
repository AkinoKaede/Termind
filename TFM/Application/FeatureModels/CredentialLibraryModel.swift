import Foundation
import TermindDomain

import struct TermindDomain.Host

/// The Keychain feature's view of the shared vault.
///
/// Keeping this surface separate prevents credential screens from mutating hosts,
/// snippets, forwarding rules, or transfers merely because those records share a
/// persistence snapshot.
@Observable
final class CredentialLibraryModel {
    private let library: HostLibraryModel

    init(library: HostLibraryModel) {
        self.library = library
    }

    var hosts: [Host] { library.hosts }
    var keys: [SSHKeyRef] { library.keys }
    var identities: [Identity] { library.identities }
    var storageError: String? { library.storageError }

    func key(_ id: SSHKeyRef.ID) -> SSHKeyRef? { library.key(id) }
    func identities(using key: SSHKeyRef.ID) -> [Identity] { library.identities(using: key) }
    func loginAddress(for host: Host) -> String { library.loginAddress(for: host) }
    func searchHosts(_ query: String) -> [Host] { library.searchHosts(query) }
    func searchKeys(_ query: String) -> [SSHKeyRef] { library.searchKeys(query) }
    func searchIdentities(_ query: String) -> [Identity] { library.searchIdentities(query) }
    func passwordAvailability(for identity: Identity) -> SecretAvailability {
        library.passwordAvailability(for: identity)
    }
    func keyAvailability(for key: SSHKeyRef) -> SecretAvailability {
        library.keyAvailability(for: key)
    }
    func keyCredential(for key: SSHKeyRef) throws -> StoredSSHKeyCredential? {
        try library.keyCredential(for: key)
    }
    func keyExportUnavailableReason(for host: Host) -> String? {
        library.keyExportUnavailableReason(for: host)
    }
    func sshConnectionConfiguration(for host: Host) throws -> SSHConnectionConfiguration {
        try library.sshConnectionConfiguration(for: host)
    }

    func upsert(_ key: SSHKeyRef, credential: StoredSSHKeyCredential? = nil) throws {
        try library.upsert(key, credential: credential)
    }
    @discardableResult
    func delete(identityID: Identity.ID) -> Bool { library.delete(identityID: identityID) }
    func delete(keyID: SSHKeyRef.ID) throws { try library.delete(keyID: keyID) }
    func move(keyIDs: [SSHKeyRef.ID], before next: SSHKeyRef.ID? = nil) {
        library.move(keyIDs: keyIDs, before: next)
    }
    func move(identityIDs: [Identity.ID], before next: Identity.ID? = nil) {
        library.move(identityIDs: identityIDs, before: next)
    }
}
