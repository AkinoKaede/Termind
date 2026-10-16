import SwiftUI
import TermindApplication
import TermindDomain

public struct LocalDiscoveryView: View {
    private let model: LocalDiscoveryModel
    @Environment(\.scenePhase) private var scenePhase
    private let select: (DiscoveredLocalHost) -> Void

    public init(model: LocalDiscoveryModel, select: @escaping (DiscoveredLocalHost) -> Void) {
        self.model = model
        self.select = select
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.phase == .scanning {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(scanning).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.hosts.isEmpty {
                ContentUnavailableView {
                    Label(AppStrings.LocalNetwork.discovery.swiftUIKey, systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text(status)
                }
            } else {
                List(model.hosts) { host in
                    Button {
                        select(host)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(host.name).font(.headline)
                            Text("\(host.address):\(host.port)").font(.callout.monospaced())
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.scan() }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.cancel() }
        }
    }

    private var scanning: LocalizedStringResource {
        model.connectionProtocol == .telnet
            ? AppStrings.LocalNetwork.scanningTelnet : AppStrings.LocalNetwork.scanning
    }

    private var status: LocalizedStringResource {
        switch model.phase {
        case .permissionDenied: AppStrings.LocalNetwork.permissionDenied
        case .unavailable, .idle: AppStrings.LocalNetwork.unavailable
        case .failed: AppStrings.LocalNetwork.scanFailed
        case .scanning: scanning
        case .finished:
            model.connectionProtocol == .telnet
                ? AppStrings.LocalNetwork.noTelnetServers : AppStrings.LocalNetwork.noServers
        }
    }
}
