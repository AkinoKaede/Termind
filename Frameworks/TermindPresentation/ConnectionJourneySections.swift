import SwiftUI
import TermindApplication
import TermindDomain

nonisolated enum ConnectionJourneySymbolPlacement {
    case header
    case routeDestination
}

extension ConnectionPurpose {
    nonisolated func symbol(for placement: ConnectionJourneySymbolPlacement) -> String {
        switch (self, placement) {
        case (.sshSession, _): "apple.terminal.fill"
        case (.moshSession, _): HostTerminalProtocol.mosh.symbol
        case (.eternalTerminalSession, _): HostTerminalProtocol.eternalTerminal.symbol
        case (.telnetSession, _): "text.rectangle.fill"
        case (.sftpChannel, .header): "folder.fill.badge.gearshape"
        case (.sftpChannel, .routeDestination): "folder.fill"
        case (.serialSession, _): "cable.connector"
        case (.metrics, _): "waveform.path.ecg"
        case (.keyExport, _): "key.fill"
        case (.portForwarding, _): "arrow.left.arrow.right"
        }
    }

    var protocolName: String {
        switch self {
        case .sshSession, .metrics, .portForwarding, .keyExport: String(localized: AppStrings.Vault.ssh)
        case .moshSession: HostTerminalProtocol.mosh.displayName
        case .eternalTerminalSession: HostTerminalProtocol.eternalTerminal.displayName
        case .telnetSession: String(localized: AppStrings.Vault.telnet)
        case .sftpChannel: String(localized: AppStrings.SFTP.sftp)
        case .serialSession: String(localized: AppStrings.Vault.serial)
        }
    }
}

public struct ConnectionJourneyHeader: View {
    let journey: ConnectionJourney
    let selectedForeground: Color
    let adaptsLogButtonForAccessibility: Bool
    let isEmbedded: Bool
    let toggleLogs: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        journey: ConnectionJourney,
        selectedForeground: Color = .white,
        adaptsLogButtonForAccessibility: Bool = true,
        isEmbedded: Bool = false,
        toggleLogs: @escaping () -> Void
    ) {
        self.journey = journey
        self.selectedForeground = selectedForeground
        self.adaptsLogButtonForAccessibility = adaptsLogButtonForAccessibility
        self.isEmbedded = isEmbedded
        self.toggleLogs = toggleLogs
    }

    public var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: journey.purpose.symbol(for: .header))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selectedForeground)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(title)
                Text(detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(detail)
            }

            Spacer(minLength: 6)

            Button(action: toggleLogs) {
                if isEmbedded || (adaptsLogButtonForAccessibility && dynamicTypeSize.isAccessibilitySize) {
                    Image(systemName: journey.showsLogs ? "eye.slash" : "list.bullet.rectangle")
                        .accessibilityLabel(journey.showsLogs ? Text("Hide Logs") : Text("Show Logs"))
                } else {
                    Text(journey.showsLogs ? "Hide Logs" : "Show Logs")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.top, isEmbedded ? 16 : 30)
        .padding(.horizontal, isEmbedded ? 16 : 34)
    }

    private var title: String { journey.destination?.name ?? journey.purpose.protocolName }

    private var detail: String {
        let protocolName = journey.purpose.protocolName
        let address = journey.destination?.address ?? ""
        if journey.mode == .reconnection {
            return String(localized: "Reconnecting \(protocolName) · \(address)")
        }
        return "\(protocolName) \(address)"
    }

}

public struct ConnectionJourneyStatus: View {
    let journey: ConnectionJourney
    let accent: Color
    let danger: Color

    public init(journey: ConnectionJourney, accent: Color = .accentColor, danger: Color = .red) {
        self.journey = journey
        self.accent = accent
        self.danger = danger
    }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.headline)
        }
        .padding(.top, 8)
    }

    private var text: String {
        switch journey.phase {
        case .connecting: String(localized: AppStrings.Connections.establishingConnection)
        case .waiting: String(localized: AppStrings.Connections.waitingForYou)
        case .succeeded:
            switch journey.purpose {
            case .sshSession, .moshSession, .eternalTerminalSession, .telnetSession, .serialSession:
                String(localized: AppStrings.Connections.terminalReady)
            case .sftpChannel: String(localized: AppStrings.Connections.fileBrowserReady)
            case .metrics: String(localized: AppStrings.Connections.metricsReady)
            case .keyExport: String(localized: AppStrings.KeyExport.completed)
            case .portForwarding: String(localized: AppStrings.Connections.forwardingReady)
            }
        case .failed(let message): message
        case .hidden: ""
        }
    }

    private var symbol: String {
        switch journey.phase {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "lock.shield"
        }
    }

    private var tint: Color {
        switch journey.phase {
        case .succeeded: accent
        case .failed: danger
        default: .secondary
        }
    }
}

public struct ConnectionJourneyReconnectStatus: View {
    let state: ReconnectState
    let accent: Color
    let retryNow: () -> Void
    let stop: () -> Void

    public init(
        state: ReconnectState,
        accent: Color = .accentColor,
        retryNow: @escaping () -> Void,
        stop: @escaping () -> Void
    ) {
        self.state = state
        self.accent = accent
        self.retryNow = retryNow
        self.stop = stop
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(accent)
                    Text(statusText(at: context.date)).font(.headline)
                }
                Text(state.lastError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        retryButton
                        stopButton
                    }
                    VStack(spacing: 10) {
                        retryButton
                        stopButton
                    }
                }
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
    }

    private var retryButton: some View {
        Button("Retry Now", action: retryNow)
            .buttonStyle(.borderedProminent)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var stopButton: some View {
        Button("Stop Reconnecting", role: .cancel, action: stop)
            .buttonStyle(.bordered)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func statusText(at date: Date) -> String {
        let seconds = max(0, Int(ceil(state.nextRetry.timeIntervalSince(date))))
        if seconds == 0 { return String(localized: AppStrings.Connections.reconnectAttempt(state.attempt)) }
        return String(localized: AppStrings.Connections.reconnectAttempt(state.attempt, retryingIn: seconds))
    }
}
