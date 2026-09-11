import AppKit
import ListViewKit
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
    var isDefaultEnabled: Bool
    var onDefault: () -> Void
    var onCancel: () -> Void

    final class HandlerView: NSView {
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
            guard let window, event.window === window, NSApp.keyWindow === window else {
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header

            ConnectionJourneyRouteView(journey: journey)

            content
                .frame(maxWidth: 660)
                .padding(.horizontal, 28)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ConnectionJourneyBackground() }
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
                        .foregroundStyle(TermindColor.selectedForeground)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(journey.destination?.name ?? String(localized: "SSH Connection"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(
                    headerDetail
                )
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button(journey.showsLogs ? "Hide Logs" : "Show Logs") {
                withAnimation(Motion.panel(reduceMotion: reduceMotion)) {
                    journey.showsLogs.toggle()
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
        } else if let prompt = authenticationPrompt {
            SSHAuthenticationForm(
                prompt: prompt,
                submit: submitAuthentication,
                cancel: cancel
            )
            .id(prompt.id)
        } else if let hostKey {
            SSHHostKeyConfirmationForm(
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
                compactActions: compactFailureActions
            )
        } else if journey.mode == .reconnection, let reconnectState {
            JourneyReconnectStatus(
                state: reconnectState,
                retryNow: retryReconnectNow ?? retry,
                stop: stopReconnecting ?? cancel
            )
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
            ConnectionLogNativeList(items: connectionLogItems) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.tertiary)
                    Text(entry.endpoint).foregroundStyle(.secondary)
                    Text(entry.message)
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
            .frame(maxHeight: 210)
        }
        .termindGlassSurface(cornerRadius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.7))
        }
    }

    private var connectionLogItems: [ConnectionLogListItem] {
        journey.logs.map {
            ConnectionLogListItem(
                id: $0.id, date: $0.date, endpoint: $0.endpoint, message: $0.message
            )
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
        case .succeeded: TermindColor.accent
        case .failed: TermindColor.danger
        default: .secondary
        }
    }

    private func copyLogs() {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(journey.plainTextLog, forType: .string)
        #endif
    }
}

nonisolated private struct ConnectionLogListItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let endpoint: String
    let message: String
}

/// The system window surface shared by a connection journey and its pane header.
struct ConnectionJourneyBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}

private struct ConnectionLogNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<ConnectionLogListItem>
    typealias Renderer = @MainActor (ConnectionLogListItem) -> AnyView
    let items: [ConnectionLogListItem]
    let renderer: Renderer
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [ConnectionLogListItem],
        @ViewBuilder renderer: @escaping @MainActor (ConnectionLogListItem) -> some View
    ) {
        self.items = items
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }
    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView, items: items, renderer: renderer,
            locale: locale, colorScheme: colorScheme
        )
    }

    @MainActor
    final class Coordinator {
        private let content = HostingListContent<ConnectionLogListItem>()
        private let measurement = NSHostingController(rootView: AnyView(EmptyView()))

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.topInset = 14
            listView.bottomInset = 14
            listView.estimatedRowHeight = 26
            listView.rows {
                ListRow(HostingListRow.self)
                    .estimatedHeight(26)
                    .height { [weak self] item, context in
                        self?.height(for: item, width: context.width) ?? 26
                    }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }

        func update(
            listView: NSViewType, items: [ConnectionLogListItem], renderer: @escaping Renderer,
            locale: Locale, colorScheme: ColorScheme
        ) {
            content.update(
                listView, items: items,
                renderer: { item in
                    AnyView(
                        renderer(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14))
                },
                locale: locale, colorScheme: colorScheme, animated: true
            )
        }

        private func height(for item: ConnectionLogListItem, width: CGFloat) -> CGFloat {
            guard width > 0, let root = content.rootView(for: item) else { return 26 }
            measurement.rootView = root
            return max(
                26,
                ceil(
                    measurement.sizeThatFits(
                        in: CGSize(
                            width: width, height: .greatestFiniteMagnitude
                        )
                    ).height) + 8)
        }

        private func configure(_ row: HostingListRow, item: ConnectionLogListItem) {
            content.configure(row, item: item)
        }
    }
}

private struct JourneyReconnectStatus: View {
    let state: ReconnectState
    let retryNow: () -> Void
    let stop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(TermindColor.accent)
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
                    Button("Retry Now", action: retryNow)
                        .buttonStyle(.borderedProminent)
                    Button("Stop Reconnecting", role: .cancel, action: stop)
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
    }

    private func statusText(at date: Date) -> String {
        let seconds = max(0, Int(ceil(state.nextRetry.timeIntervalSince(date))))
        if seconds == 0 {
            return String(localized: "Reconnect attempt \(state.attempt)…")
        }
        return String(
            localized: "Reconnect attempt \(state.attempt) · retrying in \(seconds)s"
        )
    }
}

/// Shared SSH credential form used by both the connection Journey and Agent.
/// The containing surface owns placement and queue state; this view owns the
/// established Custom/Identity choices, button language, and submission flow.
struct SSHAuthenticationForm: View {
    let prompt: SSHAuthenticationPrompt
    let submit: (Identity.ID?, String, String?, String?, SSHKeyRef.ID?, Bool) -> Void
    let cancel: () -> Void
    var usesContainerChrome = true
    @Environment(AppModel.self) private var app
    var body: some View {
        SharedSSHAuthenticationForm(
            prompt: prompt, submit: submit, cancel: cancel, usesContainerChrome: false,
            library: app.hostLibrary, keyboard: DesktopConnectionFormKeyboard()
        )
        .connectionFormChrome(isEnabled: usesContainerChrome)
    }
}

struct SSHHostKeyConfirmationForm: View {
    let prompt: SSHHostKeyPrompt
    var displayAddress: String? = nil
    let proceed: () -> Void
    let trust: (() -> Void)?
    let deny: () -> Void
    var usesContainerChrome = true
    var body: some View {
        SharedSSHHostKeyConfirmationForm(
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
            } else {
                HStack {
                    Button(cancelLabel, action: cancel).keyboardShortcut(.cancelAction)
                    Button("Copy Logs", action: copyLogs)
                    if let askAI { Button("Ask AI", action: askAI) }
                    Spacer()
                    Button(retryLabel, action: retry)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
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
}
