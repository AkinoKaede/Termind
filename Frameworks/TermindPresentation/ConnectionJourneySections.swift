import SwiftUI
import TermindApplication

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
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selectedForeground)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(journey.destination?.name ?? String(localized: "SSH Connection"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    private var detail: String {
        let protocolName: String =
            switch journey.purpose {
            case .sshSession, .metrics, .portForwarding: "SSH"
            case .sftpSession: "SFTP"
            case .serialSession: String(localized: "Serial")
            }
        let address = journey.destination?.address ?? ""
        if journey.mode == .reconnection {
            return String(localized: "Reconnecting \(protocolName) · \(address)")
        }
        return "\(protocolName) \(address)"
    }

    private var symbol: String {
        switch journey.purpose {
        case .sshSession: "apple.terminal.fill"
        case .sftpSession: "folder.fill.badge.gearshape"
        case .serialSession: "cable.connector"
        case .metrics: "waveform.path.ecg"
        case .portForwarding: "arrow.left.arrow.right"
        }
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
        case .connecting: String(localized: "Establishing connection…")
        case .waiting: String(localized: "Waiting for you…")
        case .succeeded:
            switch journey.purpose {
            case .sshSession, .serialSession: String(localized: "Terminal ready")
            case .sftpSession: String(localized: "File browser ready")
            case .metrics: String(localized: "Metrics ready")
            case .portForwarding: String(localized: "Forwarding ready")
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
        if seconds == 0 { return String(localized: "Reconnect attempt \(state.attempt)…") }
        return String(localized: "Reconnect attempt \(state.attempt) · retrying in \(seconds)s")
    }
}
