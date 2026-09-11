import SwiftUI
import TermindApplication
import TermindPresentation
import UIKit

struct MobileConnectionJourneyView: View {
    let journey: ConnectionJourney
    let library: HostLibraryModel
    let authenticationPrompt: SSHAuthenticationPrompt?
    let hostKey: SSHHostKeyPrompt?
    let reconnectState: ReconnectState?
    let submit: (UUID?, String, String?, String?, UUID?, Bool) -> Void
    let accept: (Bool) -> Void
    let retry: () -> Void
    let retryReconnectNow: () -> Void
    let stopReconnecting: () -> Void
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                ConnectionJourneyRouteView(journey: journey)

                content
                    .frame(maxWidth: 660)
                    .padding(.horizontal, 28)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, minHeight: 520, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: headerSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(journey.destination?.name ?? String(localized: "SSH Connection"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(headerDetail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    journey.showsLogs.toggle()
                }
            } label: {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: journey.showsLogs ? "eye.slash" : "list.bullet.rectangle")
                        .accessibilityLabel(journey.showsLogs ? Text("Hide Logs") : Text("Show Logs"))
                } else {
                    Text(journey.showsLogs ? "Hide Logs" : "Show Logs")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.top, 30)
        .padding(.horizontal, 34)
    }

    @ViewBuilder
    private var content: some View {
        if journey.showsLogs {
            logs
        } else if let authenticationPrompt {
            SSHAuthenticationForm(
                prompt: authenticationPrompt, submit: submit, cancel: cancel, library: library
            )
            .id(authenticationPrompt.id)
        } else if let hostKey {
            SSHHostKeyConfirmationForm(
                prompt: hostKey, displayAddress: hostKey.observation.hostname,
                proceed: { accept(false) }, trust: { accept(true) }, deny: cancel)
        } else if case .failed(let message) = journey.phase {
            MobileJourneyFailureCard(message: message, retry: retry, cancel: cancel, copyLogs: copyLogs)
        } else if let reconnectState {
            MobileReconnectStatus(
                state: reconnectState, retryNow: retryReconnectNow, stop: stopReconnecting)
        } else {
            HStack(spacing: 9) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusTint)
                Text(statusText)
                    .font(.headline)
            }
            .padding(.top, 8)
        }
    }

    private var logs: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connection Log").font(.headline)
                Spacer()
                Button("Copy", action: copyLogs).controlSize(.small)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(journey.logs) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .foregroundStyle(.tertiary)
                                Text(entry.endpoint)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.message)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 210)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.7))
        }
    }

    private var statusText: String {
        switch journey.phase {
        case .connecting: String(localized: "Establishing connection…")
        case .waiting: String(localized: "Waiting for you…")
        case .succeeded:
            switch journey.purpose {
            case .sshSession, .serialSession: String(localized: "Terminal ready")
            case .sftpSession: String(localized: "File browser ready")
            case .metrics: String(localized: "Metrics ready")
            }
        case .failed(let message): message
        case .hidden: ""
        }
    }

    private var headerDetail: String {
        let protocolName: String =
            switch journey.purpose {
            case .sshSession, .metrics: "SSH"
            case .sftpSession: "SFTP"
            case .serialSession: String(localized: "Serial")
            }
        let address = journey.destination?.address ?? ""
        if journey.mode == .reconnection {
            return String(localized: "Reconnecting \(protocolName) · \(address)")
        }
        return "\(protocolName) \(address)"
    }

    private var headerSymbol: String {
        switch journey.purpose {
        case .sshSession: "apple.terminal.fill"
        case .sftpSession: "folder.fill.badge.gearshape"
        case .serialSession: "cable.connector"
        case .metrics: "waveform.path.ecg"
        }
    }

    private var statusSymbol: String {
        switch journey.phase {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "lock.shield"
        }
    }

    private var statusTint: Color {
        switch journey.phase {
        case .succeeded: .green
        case .failed: .red
        default: .secondary
        }
    }

    private func copyLogs() {
        UIPasteboard.general.string = journey.plainTextLog
    }
}

private struct MobileJourneyFailureCard: View {
    let message: String
    let retry: () -> Void
    let cancel: () -> Void
    let copyLogs: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connection Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            actions
        }
        .padding(18)
        .background(Color.red.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.red.opacity(0.3))
        }
    }

    @ViewBuilder
    private var actions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                HStack {
                    Button("Cancel", action: cancel)
                    Button("Copy Logs", action: copyLogs)
                    Spacer()
                }
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack {
                Button("Cancel", action: cancel)
                Button("Copy Logs", action: copyLogs)
                Spacer()
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct MobileReconnectStatus: View {
    let state: ReconnectState
    let retryNow: () -> Void
    let stop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(Color.accentColor)
                    Text(statusText(at: context.date))
                        .font(.headline)
                }
                Text(state.lastError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("Retry Now", action: retryNow).buttonStyle(.borderedProminent)
                    Button("Stop Reconnecting", role: .cancel, action: stop).buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
    }

    private func statusText(at date: Date) -> String {
        let seconds = max(0, Int(ceil(state.nextRetry.timeIntervalSince(date))))
        if seconds == 0 { return String(localized: "Reconnect attempt \(state.attempt)…") }
        return String(localized: "Reconnect attempt \(state.attempt) · retrying in \(seconds)s")
    }
}
