import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

extension MobileAppModel {
    func localDiscoveryModel(protocol connectionProtocol: LocalDiscoveryProtocol) -> LocalDiscoveryModel {
        LocalDiscoveryModel(service: LANHostDiscovery(connectionProtocol: connectionProtocol))
    }

    func requestWake(_ host: Host, configure: () -> Void) -> String? {
        guard pro.require(.wakeOnLAN) else { return nil }
        let host = library.host(host.id) ?? host
        guard host.wakeOnLAN.address != nil else {
            configure()
            return nil
        }
        do {
            guard let service = library.wakeOnLAN else { throw WakeOnLANError.noLocalNetwork }
            try service.wake(host.wakeOnLAN)
            return String(localized: AppStrings.LocalNetwork.sent)
        } catch {
            return String(localized: AppStrings.LocalNetwork.wakeFailed)
        }
    }

    func macAddressModel(host: Host, custom: HostCustomIdentityDraft, tailscaleUsername: String) -> HostMACAddressModel
    {
        var submissions: [UUID: SSHAuthenticationSubmission] = [:]
        if host.isTailscaleManaged {
            submissions[host.id] = .init(username: tailscaleUsername)
        } else if host.sshIdentityID == nil || library.identity(for: host)?.isHostCustom == true,
            !custom.sshUsername.isEmpty
        {
            submissions[host.id] = .init(
                username: custom.sshUsername,
                password: custom.sshPassword.isEmpty ? nil : custom.sshPassword,
                keyID: custom.sshKeyID)
        }
        var proxies: [UUID: SSHProxyAuthenticationSubmission] = [:]
        if custom.usesCustomProxy, let proxy = host.proxy {
            proxies[host.id] = .init(
                username: proxy.username, password: custom.proxyPassword, identityID: proxy.identityID)
        }
        return HostMACAddressModel(
            host: host, library: library, resolver: hostMACResolver,
            submissions: submissions, proxies: proxies)
    }
}
