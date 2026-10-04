import SwiftUI
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// Diagnostics belong to the presented form; dismissal cancels the active ping.
public struct TailscalePeerForm: View {
    let model: TailscaleModel
    let host: Host
    let copy: (String) -> Void
    @State private var pinging = false
    @State private var result: TailscalePingResult?
    @State private var error: String?
    @State private var latencyHistory: [Double] = []

    public init(model: TailscaleModel, host: Host, copy: @escaping (String) -> Void) {
        self.model = model
        self.host = host
        self.copy = copy
    }

    public var body: some View {
        Form {
            if let peer = model.peer(for: host) {
                Section(AppStrings.Tailscale.status.swiftUIKey) {
                    TailscaleFormRow(label: AppStrings.Tailscale.status) {
                        Text(peer.online ? AppStrings.Tailscale.online : AppStrings.Tailscale.offline)
                    }
                }
                Section(AppStrings.Tailscale.addresses.swiftUIKey) {
                    TailscaleCopyField(label: AppStrings.Tailscale.magicDNS, value: peer.dnsName, copy: copy)
                    TailscaleCopyField(label: AppStrings.Vault.hostname, value: peer.name, copy: copy)
                    ForEach(peer.details?.addresses ?? [], id: \.self) { address in
                        TailscaleCopyField(
                            label: address.contains(":") ? AppStrings.Tailscale.ipv6 : AppStrings.Tailscale.ipv4,
                            value: address, copy: copy)
                    }
                }
                TailscalePingSection(
                    pinging: $pinging, result: result, error: error, history: latencyHistory,
                    isAvailable: model.canPing(host))
                if let details = peer.details {
                    Section(AppStrings.Tailscale.details.swiftUIKey) {
                        TailscaleFormRow(label: AppStrings.Tailscale.keyExpiry, symbol: "key") {
                            if let expiry = details.keyExpiry {
                                Text(expiry, format: .dateTime)
                            } else {
                                Text(AppStrings.Settings.disabled).foregroundStyle(.secondary)
                            }
                        }
                        if !details.operatingSystem.isEmpty {
                            TailscaleFormRow(label: AppStrings.Tailscale.operatingSystem, symbol: "desktopcomputer") {
                                Text(verbatim: details.operatingSystem)
                            }
                        }
                        if !peer.online, let lastSeen = details.lastSeen {
                            TailscaleFormRow(label: AppStrings.Tailscale.lastSeen, symbol: "clock") {
                                Text(lastSeen, format: .dateTime)
                            }
                        }
                    }
                }
            } else {
                Text(AppStrings.Tailscale.unavailable)
            }
        }
        .formStyle(.grouped)
        .task(id: pinging) {
            guard pinging else { return }
            result = nil
            latencyHistory = []
            error = nil
            while !Task.isCancelled {
                do {
                    let next = try await model.ping(hostID: host.id)
                    try Task.checkCancellation()
                    result = next
                    latencyHistory.append(next.milliseconds)
                    if latencyHistory.count > 30 { latencyHistory.removeFirst() }
                    error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

}
