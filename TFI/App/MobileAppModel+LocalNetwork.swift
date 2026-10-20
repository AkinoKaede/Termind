// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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

    func requestWake(_ host: Host, configure: () -> Void) async -> String? {
        do {
            switch try await library.requestWake(host) {
            case .configurationRequired:
                configure()
                return nil
            case .sent:
                return String(localized: AppStrings.LocalNetwork.sent)
            case .failed:
                return String(localized: AppStrings.LocalNetwork.wakeFailed)
            }
        } catch HostAccessError.lockedHost {
            pro.presentPaywall()
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return HostAccessError.presentationDescription(of: error)
        }
    }

    func macAddressModel(host: Host, custom: HostCustomIdentityDraft, tailscaleUsername: String) -> HostMACAddressModel
    {
        HostMACAddressModel(
            host: host, library: library, resolver: hostMACResolver,
            custom: custom, tailscaleUsername: tailscaleUsername)
    }
}
