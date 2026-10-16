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
    var securityKeySigning: SecurityKeySigningCoordinator? = nil
    var keyboardAuthentication: SSHKeyboardInteractiveQueue? = nil
    var cancelKeyboardAuthentication: (() -> Void)? = nil
    var remoteSession: RemoteSessionCoordinator? = nil
    var allowsPersistingHostKey = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ConnectionJourneyHeader(journey: journey) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        journey.showsLogs.toggle()
                    }
                }

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

    @ViewBuilder
    private var content: some View {
        if journey.showsLogs {
            logs
        } else if let coordinator = securityKeySigning, let request = coordinator.pending {
            SecurityKeySigningCard(request: request, coordinator: coordinator).id(request.id)
                .connectionFormChrome(isEnabled: true)
        } else if let queue = keyboardAuthentication, let challenge = queue.current {
            SSHKeyboardInteractiveForm(
                challenge: challenge, submit: { queue.respond(challenge.id, answers: $0) },
                cancel: {
                    guard queue.current?.id == challenge.id else { return }
                    if let cancelKeyboardAuthentication {
                        cancelKeyboardAuthentication()
                    } else {
                        queue.cancel(challenge.id)
                    }
                }, usesContainerChrome: true
            )
            .id(challenge.id)
        } else if let authenticationPrompt {
            SSHAuthenticationForm(
                prompt: authenticationPrompt, submit: submit, cancel: cancel, library: library
            )
            .id(authenticationPrompt.id)
        } else if let hostKey {
            SSHHostKeyConfirmationForm(
                prompt: hostKey, displayAddress: hostKey.observation.hostname,
                proceed: { accept(false) }, trust: allowsPersistingHostKey ? { accept(true) } : nil, deny: cancel)
        } else if let remoteSession, remoteSession.prompt != nil {
            RemoteSessionPromptView(coordinator: remoteSession, cancel: cancel)
                .connectionFormChrome(isEnabled: true)
        } else if journey.transportRecovery != nil {
            ConnectionJourneyTransportRecoveryStatus(
                journey: journey, retryNow: retryReconnectNow, close: cancel, copyLogs: copyLogs)
        } else if case .failed(let message) = journey.phase {
            MobileJourneyFailureCard(message: message, retry: retry, cancel: cancel, copyLogs: copyLogs)
        } else if let reconnectState {
            ConnectionJourneyReconnectStatus(
                state: reconnectState, retryNow: retryReconnectNow, stop: stopReconnecting)
        } else {
            ConnectionJourneyStatus(journey: journey)
        }
    }

    private var logs: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppStrings.Terminal.connectionLog).font(.headline)
                Spacer()
                Button(AppStrings.Common.copy.swiftUIKey, action: copyLogs)
                    .controlSize(.small)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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
            Label(AppStrings.Connections.connectionFailed.swiftUIKey, systemImage: "exclamationmark.triangle.fill")
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
                    Button(AppStrings.Common.cancel.swiftUIKey, action: cancel)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Button(AppStrings.Terminal.copyLogs.swiftUIKey, action: copyLogs)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                }
                Button(AppStrings.Common.retry.swiftUIKey, action: retry)
                    .buttonStyle(.borderedProminent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey, action: cancel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Button(AppStrings.Terminal.copyLogs.swiftUIKey, action: copyLogs)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                Button(AppStrings.Common.retry.swiftUIKey, action: retry)
                    .buttonStyle(.borderedProminent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
