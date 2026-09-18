import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

nonisolated enum ActiveFormKeyDecision: Equatable, Sendable {
    case passThrough
    case consume
    case submit
    case cancel

    static func resolve(
        keyCode: UInt16, hasModifiers: Bool, hasMarkedText: Bool,
        isRepeat: Bool, isDefaultEnabled: Bool
    ) -> Self {
        guard !hasModifiers, keyCode == 36 || keyCode == 76 || keyCode == 53 else {
            return .passThrough
        }
        guard !hasMarkedText else { return .passThrough }
        guard !isRepeat else { return .consume }
        if keyCode == 53 { return .cancel }
        return isDefaultEnabled ? .submit : .consume
    }
}

/// Window-scoped Return/Escape handling for the foremost decision form.
///
/// Button key equivalents alone are ambiguous when an outer surface also owns
/// Escape (the Assistant sidebar's Back button is one example). A local event
/// monitor lets the visible form consume exactly one unmodified key press while
/// still yielding to an IME composition or a menu in another key window.
private struct ActiveFormKeyboardBridge: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var isDefaultEnabled: Bool
    var onDefault: () -> Void
    var onCancel: () -> Void

    final class HandlerView: NSView {
        var isEnabled = true
        var isDefaultEnabled = false
        var onDefault: () -> Void = {}
        var onCancel: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func stop() { removeMonitor() }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let window, event.window === window, NSApp.keyWindow === window else {
                return event
            }
            // Caps Lock and the numeric-pad flag do not turn Return/Escape
            // into modified shortcuts. In particular, keypad Enter arrives
            // with `.numericPad` and should behave exactly like Return.
            let commandModifiers = event.modifierFlags.intersection([
                .shift, .control, .option, .command,
            ])
            let decision = ActiveFormKeyDecision.resolve(
                keyCode: event.keyCode,
                hasModifiers: !commandModifiers.isEmpty,
                hasMarkedText: (window.firstResponder as? NSTextView)?.hasMarkedText() ?? false,
                isRepeat: event.isARepeat,
                isDefaultEnabled: isDefaultEnabled
            )
            switch decision {
            case .passThrough:
                return event
            case .consume:
                return nil
            case .cancel:
                onCancel()
            case .submit:
                onDefault()
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> HandlerView {
        let view = HandlerView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ nsView: HandlerView, context: Context) { update(nsView) }

    static func dismantleNSView(_ nsView: HandlerView, coordinator: ()) {
        nsView.stop()
    }

    private func update(_ view: HandlerView) {
        view.isEnabled = isEnabled
        view.isDefaultEnabled = isDefaultEnabled
        view.onDefault = onDefault
        view.onCancel = onCancel
    }
}

extension View {
    func activeFormKeyboardActions(
        isDefaultEnabled: Bool,
        onDefault: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        background {
            ActiveFormKeyboardBridge(
                isDefaultEnabled: isDefaultEnabled,
                onDefault: onDefault,
                onCancel: onCancel
            )
            .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    fileprivate func connectionFormChrome(isEnabled: Bool) -> some View {
        if isEnabled {
            padding(18)
                .termindGlassSurface(cornerRadius: 14)
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.separator.opacity(0.7))
                }
        } else {
            self
        }
    }
}

struct ConnectionJourneyView: View {
    let journey: ConnectionJourney
    var authenticationPrompt: SSHAuthenticationPrompt?
    var hostKey: SSHHostKeyPrompt?
    var submitAuthentication: (Identity.ID?, String, String?, String?, SSHKeyRef.ID?, Bool) -> Void
    var continueHostKey: (SSHHostKeyObservation) -> Void
    var trustHostKey: (SSHHostKeyObservation) -> Void
    var denyHostKey: () -> Void
    var retry: () -> Void
    var cancel: () -> Void
    var askAI: (() -> Void)?
    var reconnectState: ReconnectState? = nil
    var retryReconnectNow: (() -> Void)? = nil
    var stopReconnecting: (() -> Void)? = nil
    var failureCancelLabel: LocalizedStringKey = "Cancel"
    var failureRetryLabel: LocalizedStringKey = "Retry"
    var compactFailureActions = false
    var keyboardAuthentication: SSHKeyboardInteractiveQueue? = nil
    var cancelKeyboardAuthentication: (() -> Void)? = nil
    var isEmbedded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isEmbedded {
                ScrollView { journeyContent }
            } else {
                journeyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ConnectionJourneyBackground() }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private var journeyContent: some View {
        VStack(spacing: 0) {
            ConnectionJourneyHeader(
                journey: journey,
                selectedForeground: TermindColor.selectedForeground,
                adaptsLogButtonForAccessibility: false,
                isEmbedded: isEmbedded
            ) {
                withAnimation(Motion.panel(reduceMotion: reduceMotion)) {
                    journey.showsLogs.toggle()
                }
            }

            ConnectionJourneyRouteView(journey: journey)

            content
                .frame(maxWidth: 660)
                .padding(.horizontal, isEmbedded ? 16 : 28)
                .fixedSize(horizontal: false, vertical: isEmbedded)

            Spacer(minLength: 24)
        }
    }

    @ViewBuilder
    private var content: some View {
        if journey.showsLogs {
            logs
        } else if let queue = keyboardAuthentication, let challenge = queue.current {
            SSHKeyboardInteractiveForm(
                challenge: challenge,
                submit: { queue.respond(challenge.id, answers: $0) },
                cancel: {
                    guard queue.current?.id == challenge.id else { return }
                    if let cancelKeyboardAuthentication {
                        cancelKeyboardAuthentication()
                    } else {
                        queue.cancel(challenge.id)
                    }
                },
                keyboard: DesktopConnectionFormKeyboard()
            )
            .id(challenge.id)
            .connectionFormChrome(isEnabled: true)
        } else if let prompt = authenticationPrompt {
            DesktopSSHAuthenticationForm(
                prompt: prompt,
                submit: submitAuthentication,
                cancel: cancel
            )
            .id(prompt.id)
        } else if let hostKey {
            DesktopSSHHostKeyConfirmationForm(
                prompt: hostKey,
                proceed: { continueHostKey(hostKey.observation) },
                trust: { trustHostKey(hostKey.observation) },
                deny: denyHostKey
            )
        } else if case .failed(let message) = journey.phase {
            JourneyFailureCard(
                message: message, retry: retry, cancel: cancel,
                copyLogs: copyLogs, askAI: askAI,
                cancelLabel: failureCancelLabel,
                retryLabel: failureRetryLabel,
                compactActions: compactFailureActions,
                adaptsActions: isEmbedded
            )
        } else if journey.mode == .reconnection, let reconnectState {
            ConnectionJourneyReconnectStatus(
                state: reconnectState,
                accent: TermindColor.accent,
                retryNow: retryReconnectNow ?? retry,
                stop: stopReconnecting ?? cancel
            )
        } else {
            ConnectionJourneyStatus(
                journey: journey,
                accent: TermindColor.accent,
                danger: TermindColor.danger
            )
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
                        if isEmbedded {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(entry.date, format: .dateTime.hour().minute().second())
                                        .foregroundStyle(.tertiary)
                                    Text(entry.endpoint).foregroundStyle(.secondary)
                                }
                                Text(entry.message)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .foregroundStyle(.tertiary)
                                Text(entry.endpoint).foregroundStyle(.secondary)
                                Text(entry.message)
                            }
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(height: isEmbedded ? 210 : nil)
            .frame(maxHeight: 210)
        }
        .termindGlassSurface(cornerRadius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.7))
        }
    }

    private func copyLogs() {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(journey.plainTextLog, forType: .string)
        #endif
    }
}

/// The system window surface shared by a connection journey and its pane header.
struct ConnectionJourneyBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}

/// Shared SSH credential form used by both the connection Journey and Agent.
/// The containing surface owns placement and queue state; this view owns the
/// established Custom/Identity choices, button language, and submission flow.
struct DesktopSSHAuthenticationForm: View {
    let prompt: SSHAuthenticationPrompt
    let submit: (Identity.ID?, String, String?, String?, SSHKeyRef.ID?, Bool) -> Void
    let cancel: () -> Void
    var usesContainerChrome = true
    var respondKeyboardInteractive: (([String]) -> Void)? = nil
    @Environment(AppModel.self) private var app
    var body: some View {
        TermindPresentation.SSHAuthenticationForm(
            prompt: prompt, submit: submit, cancel: cancel, usesContainerChrome: false,
            library: app.hostLibrary, keyboard: DesktopConnectionFormKeyboard(),
            respondKeyboardInteractive: respondKeyboardInteractive
        )
        .connectionFormChrome(isEnabled: usesContainerChrome)
    }
}

struct DesktopSSHHostKeyConfirmationForm: View {
    let prompt: SSHHostKeyPrompt
    var displayAddress: String? = nil
    let proceed: () -> Void
    let trust: (() -> Void)?
    let deny: () -> Void
    var usesContainerChrome = true
    var body: some View {
        TermindPresentation.SSHHostKeyConfirmationForm(
            prompt: prompt, displayAddress: displayAddress, proceed: proceed,
            trust: trust, deny: deny, usesContainerChrome: false, keyboard: DesktopConnectionFormKeyboard()
        )
        .connectionFormChrome(isEnabled: usesContainerChrome)
    }
}

private struct DesktopConnectionFormKeyboard: ConnectionFormKeyboardAdapting {
    func bridge(canSubmit: Bool, submit: @escaping () -> Void, cancel: @escaping () -> Void) -> AnyView {
        AnyView(
            Color.clear.activeFormKeyboardActions(isDefaultEnabled: canSubmit, onDefault: submit, onCancel: cancel)
                .frame(width: 0, height: 0))
    }
}

private struct JourneyFailureCard: View {
    let message: String
    let retry: () -> Void
    let cancel: () -> Void
    let copyLogs: () -> Void
    let askAI: (() -> Void)?
    let cancelLabel: LocalizedStringKey
    let retryLabel: LocalizedStringKey
    let compactActions: Bool
    let adaptsActions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connection Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(TermindColor.danger)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            if compactActions {
                HStack {
                    Button(action: cancel) {
                        Text(cancelLabel).frame(width: 88)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(action: retry) {
                        Text(retryLabel).frame(width: 88)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            } else if adaptsActions {
                ViewThatFits(in: .horizontal) {
                    actions
                    VStack(alignment: .leading, spacing: 10) {
                        secondaryActions
                        retryButton.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                actions
            }
        }
        .padding(compactActions ? 14 : 18)
        .frame(maxWidth: compactActions ? 380 : nil)
        .background(TermindColor.danger.opacity(0.065), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(TermindColor.danger.opacity(0.3))
        }
    }

    private var actions: some View {
        HStack {
            secondaryActions
            Spacer()
            retryButton
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button(cancelLabel, action: cancel).keyboardShortcut(.cancelAction)
        Button("Copy Logs", action: copyLogs)
        if let askAI { Button("Ask AI", action: askAI) }
    }

    private var retryButton: some View {
        Button(retryLabel, action: retry)
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
    }
}
