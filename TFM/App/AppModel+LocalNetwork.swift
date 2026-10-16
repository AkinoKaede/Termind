import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

extension AppModel {
    func localDiscoveryModel(protocol connectionProtocol: LocalDiscoveryProtocol) -> LocalDiscoveryModel {
        LocalDiscoveryModel(service: LANHostDiscovery(connectionProtocol: connectionProtocol))
    }

    func requestWake(_ host: Host, configure: () -> Void) -> String? {
        switch hostLibrary.requestWake(host, requestAccess: { proAccess.require(.wakeOnLAN) }) {
        case .accessDenied:
            return nil
        case .configurationRequired:
            configure()
            return nil
        case .sent:
            return String(localized: AppStrings.LocalNetwork.sent)
        case .failed:
            return String(localized: AppStrings.LocalNetwork.wakeFailed)
        }
    }

    func macAddressModel(host: Host, custom: HostCustomIdentityDraft, tailscaleUsername: String) -> HostMACAddressModel
    {
        HostMACAddressModel(
            host: host, library: hostLibrary, resolver: SSHHostMACAddressResolver(coordinator: connections),
            custom: custom, tailscaleUsername: tailscaleUsername)
    }
}
