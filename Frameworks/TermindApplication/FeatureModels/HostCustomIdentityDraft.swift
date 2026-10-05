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
    public var telnetUsername = ""
    public var telnetPassword = ""
    public private(set) var usesCustomTelnetSelection = false
    public var usesCustomProxy = false
    public var proxyPassword = ""
    public var usesCustomTelnetProxy = false
    public var telnetProxyPassword = ""

    private var sshIdentityID: Identity.ID?
    private var telnetIdentityID: Identity.ID?
    private var sshHasConfiguredPassword = false
    private var telnetHasConfiguredPassword = false
    private var proxyHasConfiguredPassword = false
    private var telnetProxyHasConfiguredPassword = false
    private var sshPasswordAvailability: SecretAvailability = .notConfigured
    private var telnetPasswordAvailability: SecretAvailability = .notConfigured
    private var proxyPasswordAvailability: SecretAvailability = .notConfigured
    private var telnetProxyPasswordAvailability: SecretAvailability = .notConfigured

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

        let telnet = library.customIdentity(for: host.id, purpose: .telnet)
        telnetIdentityID = telnet?.id
        telnetUsername = telnet?.username ?? ""
        telnetHasConfiguredPassword = telnet?.usesPassword == true
        if let telnet {
            telnetPasswordAvailability = library.passwordAvailability(for: telnet)
            if telnetPasswordAvailability == .available {
                telnetPassword = (try? library.editablePassword(for: telnet)) ?? ""
            }
        }
        usesCustomTelnetSelection = host.telnetIdentityID == telnet?.id && telnet != nil

        let proxy = library.customIdentity(for: host.id, purpose: .proxy)
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

        let telnetProxy = library.customIdentity(for: host.id, purpose: .telnetProxy)
        telnetProxyHasConfiguredPassword = telnetProxy?.usesPassword == true
        if let telnetProxy {
            telnetProxyPasswordAvailability = library.passwordAvailability(for: telnetProxy)
            if host.telnetProxy?.identityID == telnetProxy.id {
                usesCustomTelnetProxy = true
                if telnetProxyPasswordAvailability == .available {
                    telnetProxyPassword = (try? library.editablePassword(for: telnetProxy)) ?? ""
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

    public var telnetPasswordIsEditable: Bool {
        !telnetHasConfiguredPassword || telnetPasswordAvailability == .available
    }

    public var telnetProxyPasswordIsEditable: Bool {
        !telnetProxyHasConfiguredPassword || telnetProxyPasswordAvailability == .available
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

    public func usesCustomTelnet(for host: Host) -> Bool {
        usesCustomTelnetSelection && (host.telnetIdentityID == nil || host.telnetIdentityID == telnetIdentityID)
    }

    public mutating func selectCustomTelnet(on host: inout Host) {
        usesCustomTelnetSelection = true
        host.telnetIdentityID = telnetIdentityID
    }

    public mutating func clearTelnetIdentity(on host: inout Host) {
        usesCustomTelnetSelection = false
        host.telnetIdentityID = nil
    }

    public mutating func selectTelnetIdentity(_ identity: Identity, on host: inout Host) {
        usesCustomTelnetSelection = false
        host.telnetIdentityID = identity.id
    }

    public mutating func clearProxyIdentity(on host: inout Host) {
        usesCustomProxy = false
        host.proxy?.identityID = nil
        host.proxy?.username = ""
    }

    public mutating func selectCustomProxy(on host: inout Host, using library: HostLibraryModel) {
        usesCustomProxy = true
        let identity = library.customIdentity(for: host.id, purpose: .proxy)
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

    public mutating func clearTelnetProxyIdentity(on host: inout Host) {
        usesCustomTelnetProxy = false
        host.telnetProxy?.identityID = nil
        host.telnetProxy?.username = ""
    }

    public mutating func selectCustomTelnetProxy(on host: inout Host, using library: HostLibraryModel) {
        usesCustomTelnetProxy = true
        let identity = library.customIdentity(for: host.id, purpose: .telnetProxy)
        telnetProxyHasConfiguredPassword = identity?.usesPassword == true
        telnetProxyPasswordAvailability = identity.map(library.passwordAvailability) ?? .notConfigured
        host.telnetProxy?.identityID = identity?.id
        host.telnetProxy?.username = identity?.username ?? ""
        telnetProxyPassword = ""
        if let identity, telnetProxyPasswordAvailability == .available {
            telnetProxyPassword = (try? library.editablePassword(for: identity)) ?? ""
        }
    }

    public mutating func selectTelnetProxyIdentity(_ identity: Identity, on host: inout Host) {
        usesCustomTelnetProxy = false
        host.telnetProxy?.identityID = identity.id
        host.telnetProxy?.username = identity.username
    }

    public func isSSHValid(for host: Host) -> Bool {
        guard host.sshEnabled else { return true }
        return !usesCustomSSH(for: host)
            || (!sshUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (sshPassword.isEmpty && sshKeyID == nil))
    }

    public func isProxyValid(for host: Host) -> Bool {
        guard host.sshEnabled else { return true }
        guard let proxy = host.proxy else { return true }
        guard usesCustomProxy else { return proxy.isValid }

        let username = proxy.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPassword = !proxyPassword.isEmpty || proxyHasConfiguredPassword
        let hasAuthentication = !username.isEmpty || hasPassword
        return !proxy.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(proxy.port)
            && (!hasAuthentication || (!username.isEmpty && hasPassword))
    }

    public func isTelnetValid(for host: Host) -> Bool {
        guard host.telnetEnabled else { return true }
        guard (1...65_535).contains(host.telnetPort) else { return false }
        guard usesCustomTelnet(for: host) else { return true }
        let username = telnetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return !username.isEmpty && (!telnetPassword.isEmpty || telnetHasConfiguredPassword)
    }

    public func isTelnetProxyValid(for host: Host) -> Bool {
        guard host.telnetEnabled, let proxy = host.telnetProxy else { return true }
        guard usesCustomTelnetProxy else { return proxy.isValid }
        let username = proxy.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPassword = !telnetProxyPassword.isEmpty || telnetProxyHasConfiguredPassword
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

        if usesCustomTelnet(for: host), host.telnetEnabled {
            let identity = try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .telnet, displayName: "\(host.name) Telnet",
                username: telnetUsername, password: telnetPassword, keyID: nil)
            host.telnetIdentityID = identity?.id
            telnetIdentityID = identity?.id
            telnetHasConfiguredPassword = identity?.usesPassword == true
            telnetPasswordAvailability = identity.map(library.passwordAvailability) ?? .notConfigured
        }

        if usesCustomProxy, let proxy = host.proxy {
            let identity = try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .proxy, displayName: "\(host.name) Proxy",
                username: proxy.username, password: proxyPassword, keyID: nil)
            host.proxy?.identityID = identity?.id
            proxyHasConfiguredPassword = identity?.usesPassword == true
            proxyPasswordAvailability = identity.map(library.passwordAvailability) ?? .notConfigured
        } else if host.proxy == nil {
            _ = try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .proxy, displayName: "",
                username: "", password: "", keyID: nil)
            proxyHasConfiguredPassword = false
            proxyPasswordAvailability = .notConfigured
        }

        if usesCustomTelnetProxy, let proxy = host.telnetProxy {
            let identity = try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .telnetProxy,
                displayName: "\(host.name) Telnet Proxy",
                username: proxy.username, password: telnetProxyPassword, keyID: nil)
            host.telnetProxy?.identityID = identity?.id
            telnetProxyHasConfiguredPassword = identity?.usesPassword == true
            telnetProxyPasswordAvailability = identity.map(library.passwordAvailability) ?? .notConfigured
        } else if host.telnetProxy == nil {
            _ = try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .telnetProxy, displayName: "",
                username: "", password: "", keyID: nil)
            telnetProxyHasConfiguredPassword = false
            telnetProxyPasswordAvailability = .notConfigured
        }

        guard library.saveHost(host) else {
            throw TermindSSHError.library(
                library.storageError ?? String(localized: "The host could not be saved."))
        }
    }
}
