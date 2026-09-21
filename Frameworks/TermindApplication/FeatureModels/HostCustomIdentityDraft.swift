import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Memory-only Custom Identity fields shared by the native Host editors.
///
/// Passwords live here only for the lifetime of an editor. This value is never
/// persisted, synchronized, logged, or given a textual representation.
@MainActor
public struct HostCustomIdentityDraft {
    public var sshUsername = ""
    public var sshPassword = ""
    public var sshKeyID: SSHKeyRef.ID?
    public var usesCustomProxy = false
    public var proxyPassword = ""

    private var sshIdentityID: Identity.ID?
    private var proxyIdentityID: Identity.ID?
    private var sshHasConfiguredPassword = false
    private var proxyHasConfiguredPassword = false
    private var sshPasswordAvailability: SecretAvailability = .notConfigured
    private var proxyPasswordAvailability: SecretAvailability = .notConfigured

    public init() {}

    public init(host: Host, library: HostLibraryModel) {
        let ssh = library.customIdentity(for: host.id, purpose: .ssh)
        sshIdentityID = ssh?.id
        sshUsername = ssh?.username ?? ""
        sshKeyID = ssh?.keyID
        sshHasConfiguredPassword = ssh?.usesPassword == true
        if let ssh {
            sshPasswordAvailability = library.passwordAvailability(for: ssh)
            if sshPasswordAvailability == .available {
                sshPassword = (try? library.editablePassword(for: ssh)) ?? ""
            }
        }

        let proxy = library.customIdentity(for: host.id, purpose: .proxy)
        proxyIdentityID = proxy?.id
        proxyHasConfiguredPassword = proxy?.usesPassword == true
        if let proxy {
            proxyPasswordAvailability = library.passwordAvailability(for: proxy)
            if host.proxy?.identityID == proxy.id {
                usesCustomProxy = true
                if proxyPasswordAvailability == .available {
                    proxyPassword = (try? library.editablePassword(for: proxy)) ?? ""
                }
            }
        }
    }

    public var sshPasswordIsEditable: Bool {
        !sshHasConfiguredPassword || sshPasswordAvailability == .available
    }

    public var proxyPasswordIsEditable: Bool {
        !proxyHasConfiguredPassword || proxyPasswordAvailability == .available
    }

    public func usesCustomSSH(for host: Host) -> Bool {
        guard let identityID = host.identityID else { return true }
        return identityID == sshIdentityID
    }

    public func selectCustomSSH(on host: inout Host) {
        host.identityID = sshIdentityID
    }

    public func selectSSHIdentity(_ identity: Identity, on host: inout Host) {
        host.identityID = identity.id
    }

    public mutating func clearProxyIdentity(on host: inout Host) {
        usesCustomProxy = false
        host.proxy?.identityID = nil
        host.proxy?.username = ""
    }

    public mutating func selectCustomProxy(on host: inout Host, using library: HostLibraryModel) {
        usesCustomProxy = true
        let identity = library.customIdentity(for: host.id, purpose: .proxy)
        proxyIdentityID = identity?.id
        proxyHasConfiguredPassword = identity?.usesPassword == true
        proxyPasswordAvailability = identity.map(library.passwordAvailability) ?? .notConfigured
        host.proxy?.identityID = identity?.id
        host.proxy?.username = identity?.username ?? ""
        proxyPassword = ""
        if let identity, proxyPasswordAvailability == .available {
            proxyPassword = (try? library.editablePassword(for: identity)) ?? ""
        }
    }

    public mutating func selectProxyIdentity(_ identity: Identity, on host: inout Host) {
        usesCustomProxy = false
        host.proxy?.identityID = identity.id
        host.proxy?.username = identity.username
    }

    public func isSSHValid(for host: Host) -> Bool {
        !usesCustomSSH(for: host)
            || (!sshUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (sshPassword.isEmpty && sshKeyID == nil))
    }

    public func isProxyValid(for host: Host) -> Bool {
        guard let proxy = host.proxy else { return true }
        guard usesCustomProxy else { return proxy.isValid }

        let username = proxy.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPassword = !proxyPassword.isEmpty || proxyHasConfiguredPassword
        let hasAuthentication = !username.isEmpty || hasPassword
        return !proxy.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(proxy.port)
            && (!hasAuthentication || (!username.isEmpty && hasPassword))
    }

    public mutating func save(into host: inout Host, using library: HostLibraryModel) throws {
        if usesCustomSSH(for: host) {
            let identity = try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .ssh, displayName: host.name,
                username: sshUsername, password: sshPassword, keyID: sshKeyID)
            host.identityID = identity?.id
            sshIdentityID = identity?.id
            sshHasConfiguredPassword = identity?.usesPassword == true
            sshPasswordAvailability = identity.map(library.passwordAvailability) ?? .notConfigured
        }

        if usesCustomProxy, let proxy = host.proxy {
            let identity = try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .proxy, displayName: "\(host.name) Proxy",
                username: proxy.username, password: proxyPassword, keyID: nil)
            host.proxy?.identityID = identity?.id
            proxyIdentityID = identity?.id
            proxyHasConfiguredPassword = identity?.usesPassword == true
            proxyPasswordAvailability = identity.map(library.passwordAvailability) ?? .notConfigured
        } else if host.proxy == nil {
            _ = try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .proxy, displayName: "",
                username: "", password: "", keyID: nil)
            proxyIdentityID = nil
            proxyHasConfiguredPassword = false
            proxyPasswordAvailability = .notConfigured
        }

        guard library.saveHost(host) else {
            throw TermindSSHError.library(
                library.storageError ?? String(localized: "The host could not be saved."))
        }
    }
}
