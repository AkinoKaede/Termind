import Foundation
import TermindDomain

import struct TermindDomain.Host

/// The Keychain feature's view of the shared vault.
///
/// Keeping this surface separate prevents credential screens from mutating hosts,
/// snippets, forwarding rules, or transfers merely because those records share a
/// persistence snapshot.
@Observable
public final class CredentialLibraryModel {
    private let library: HostLibraryModel

    public init(library: HostLibraryModel) {
        self.library = library
    }

    public var hosts: [Host] { library.hosts }
    public var keys: [SSHKeyRef] { library.keys }
    public var identities: [Identity] { library.reusableIdentities }
    public var storageError: String? { library.storageError }

    public func key(_ id: SSHKeyRef.ID) -> SSHKeyRef? { library.key(id) }
    public func identities(using key: SSHKeyRef.ID) -> [Identity] { library.identities(using: key) }
    public func loginAddress(for host: Host) -> String { library.loginAddress(for: host) }
    public func searchHosts(_ query: String) -> [Host] { library.searchHosts(query) }
    public func searchKeys(_ query: String) -> [SSHKeyRef] { library.searchKeys(query) }
    public func searchIdentities(_ query: String) -> [Identity] { library.searchIdentities(query) }
    public func passwordAvailability(for identity: Identity) -> SecretAvailability {
        library.passwordAvailability(for: identity)
    }
    public func editablePassword(for identity: Identity) throws -> String? {
        try library.editablePassword(for: identity)
    }
    public func keyAvailability(for key: SSHKeyRef) -> SecretAvailability {
        library.keyAvailability(for: key)
    }
    public func keyCredential(for key: SSHKeyRef) throws -> StoredSSHKeyCredential? {
        try library.keyCredential(for: key)
    }
    public func keyExportUnavailableReason(for host: Host) -> String? {
        library.keyExportUnavailableReason(for: host)
    }
    public func prepareSSHConnection(for host: Host) throws -> SSHConnectionPreparation {
        try library.prepareSSHConnection(for: host, submissions: [:])
    }

    public func upsert(_ key: SSHKeyRef, credential: StoredSSHKeyCredential? = nil) throws {
        try library.upsert(key, credential: credential)
    }
    @discardableResult
    public func delete(identityID: Identity.ID) -> Bool { library.delete(identityID: identityID) }
    public func delete(keyID: SSHKeyRef.ID) throws { try library.delete(keyID: keyID) }
    public func move(keyIDs: [SSHKeyRef.ID], before next: SSHKeyRef.ID? = nil) {
        library.move(keyIDs: keyIDs, before: next)
    }
    public func move(identityIDs: [Identity.ID], before next: Identity.ID? = nil) {
        library.move(identityIDs: identityIDs, before: next)
    }
}
