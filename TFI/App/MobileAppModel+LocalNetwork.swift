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
        switch library.requestWake(host, requestAccess: { pro.require(.wakeOnLAN) }) {
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
            host: host, library: library, resolver: hostMACResolver,
            custom: custom, tailscaleUsername: tailscaleUsername)
    }
}
