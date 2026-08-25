import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

struct SSHConnectionJourneyView: View {
    let journey: SSHConnectionJourney
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        route(viewportWidth: geometry.size.width)
                            .padding(.vertical, 30)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: journey.activeEndpointIndex) { _, _ in
                        scrollToActivity(proxy)
                    }
                    .onChange(of: journey.checkpoint) { _, _ in
                        scrollToActivity(proxy)
                    }
                }
            }
            .frame(height: 152)

            content
                .frame(maxWidth: 660)
                .padding(.horizontal, 28)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.055), .clear],
                    center: .topLeading, startRadius: 20, endRadius: 520
                )
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(
                        systemName: journey.purpose == .sshSession
                            ? "apple.terminal.fill" : "folder.fill.badge.gearshape"
                    )
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
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

    private func route(viewportWidth: CGFloat) -> some View {
        let nodeLaneHeight: CGFloat = 56
        let endpointSpacing: CGFloat = 190
        let labelWidth: CGFloat = 150
        let gapBetweenEndpointFrames = endpointSpacing - labelWidth
        let routeWidth = labelWidth + CGFloat(max(0, journey.endpoints.count - 1)) * endpointSpacing
        let canvasWidth = max(viewportWidth, routeWidth + 58)

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(1..<journey.endpoints.count, id: \.self) { index in
                    JourneySegmentView(
                        state: segmentState(for: index),
                        checkpoint: journey.checkpoint?.endpointIndex == index
                            ? journey.checkpoint?.kind : journey.completedCheckpoints[index],
                        checkpointIsWaiting: journey.checkpoint?.endpointIndex == index,
                        reduceMotion: reduceMotion
                    )
                    .frame(width: endpointSpacing, height: nodeLaneHeight)
                    .id("segment-\(index)")
                }
            }
            .padding(.leading, labelWidth / 2)

            HStack(alignment: .top, spacing: gapBetweenEndpointFrames) {
                ForEach(Array(journey.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                    JourneyEndpointView(
                        endpoint: endpoint,
                        purpose: journey.purpose,
                        state: endpointState(for: index),
                        showsActivity: activityEndpointIndex == index,
                        localRequirement: index == 0 ? journey.localRequirement : nil,
                        reduceMotion: reduceMotion
                    )
                    .frame(width: labelWidth, height: 92, alignment: .top)
                    .id("endpoint-\(index)")
                }
            }
        }
        .frame(width: routeWidth, height: 92, alignment: .topLeading)
        .frame(width: canvasWidth, height: 92, alignment: .center)
    }

    @ViewBuilder
    private var content: some View {
        if journey.showsLogs {
            logs
        } else if let prompt = authenticationPrompt {
            JourneyAuthenticationCard(
                prompt: prompt,
                submit: submitAuthentication,
                cancel: cancel
            )
            .id(prompt.id)
        } else if let hostKey {
            JourneyHostKeyCard(
                prompt: hostKey,
                proceed: { continueHostKey(hostKey.observation) },
                trust: { trustHostKey(hostKey.observation) },
                deny: denyHostKey
            )
        } else if case .failed(let message) = journey.phase {
            JourneyFailureCard(
                message: message, retry: retry, cancel: cancel,
                copyLogs: copyLogs, askAI: askAI
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(journey.logs) { entry in
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxHeight: 210)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.7))
        }
    }

    private var statusText: String {
        switch journey.phase {
        case .connecting: String(localized: "Establishing connection…")
        case .waiting: String(localized: "Waiting for you…")
        case .succeeded:
            journey.purpose == .sshSession
                ? String(localized: "Terminal ready") : String(localized: "File browser ready")
        case .failed(let message): message
        case .hidden: ""
        }
    }

    private var headerDetail: String {
        let protocolName = journey.purpose == .sshSession ? "SSH" : "SFTP"
        let address = journey.destination?.address ?? ""
        if journey.mode == .reconnection {
            return String(localized: "Reconnecting \(protocolName) · \(address)")
        }
        return "\(protocolName) \(address)"
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
        case .succeeded: .blue
        case .failed: .red
        default: .secondary
        }
    }

    private var activityEndpointIndex: Int? {
        guard journey.phase == .connecting, journey.checkpoint == nil else { return nil }
        if journey.activeEndpointIndex > journey.completedEndpointIndex {
            return max(0, journey.activeEndpointIndex - 1)
        }
        return journey.completedEndpointIndex
    }

    private func endpointState(for index: Int) -> JourneyVisualState {
        if case .failed = journey.phase, index <= journey.activeEndpointIndex { return .failed }
        if index <= journey.completedEndpointIndex { return .complete }
        return .pending
    }

    private func segmentState(for targetIndex: Int) -> JourneyVisualState {
        if case .failed = journey.phase, targetIndex <= journey.activeEndpointIndex { return .failed }
        if targetIndex <= journey.completedEndpointIndex { return .complete }
        if targetIndex == journey.activeEndpointIndex { return .active }
        return .pending
    }

    private func scrollToActivity(_ proxy: ScrollViewProxy) {
        guard !reduceMotion else { return }
        let index = journey.checkpoint?.endpointIndex ?? journey.activeEndpointIndex
        withAnimation(.easeInOut(duration: 0.24)) {
            proxy.scrollTo(
                journey.checkpoint == nil ? "endpoint-\(index)" : "segment-\(index)",
                anchor: .center
            )
        }
    }

    private func copyLogs() {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(journey.plainTextLog, forType: .string)
        #endif
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
                        .foregroundStyle(.blue)
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

private enum JourneyVisualState {
    case pending
    case active
    case complete
    case failed

    var color: Color {
        switch self {
        case .pending: .secondary.opacity(0.55)
        case .active, .complete: .blue
        case .failed: .red
        }
    }
}

private struct JourneyEndpointView: View {
    let endpoint: SSHConnectionEndpoint
    let purpose: SSHConnectionPurpose
    let state: JourneyVisualState
    let showsActivity: Bool
    let localRequirement: SSHConnectionJourney.LocalRequirement?
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                if showsActivity {
                    JourneyActivityRing(size: 52, reduceMotion: reduceMotion)
                }
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 38, height: 38)
                Circle()
                    .fill(state.color)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
            .frame(width: 56, height: 56)

            Text(endpoint.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
        }
        .frame(height: 92, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.name), \(accessibilityState)")
    }

    private var symbol: String {
        switch endpoint.role {
        case .local:
            switch localRequirement {
            case .identity: "person.fill"
            case .passphrase: "key.fill"
            case nil: "laptopcomputer"
            }
        case .jump: "server.rack"
        case .destination:
            purpose == .sshSession ? "apple.terminal.fill" : "folder.fill"
        }
    }

    private var accessibilityState: String {
        switch state {
        case .pending: String(localized: "not connected")
        case .active: String(localized: "connecting")
        case .complete: String(localized: "connected")
        case .failed: String(localized: "failed")
        }
    }
}

private struct JourneySegmentView: View {
    let state: JourneyVisualState
    let checkpoint: SSHConnectionJourney.CheckpointKind?
    let checkpointIsWaiting: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.32)).frame(height: 4)
                switch state {
                case .complete, .failed:
                    Capsule().fill(state.color).frame(height: 4)
                case .active:
                    if checkpointIsWaiting {
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.blue)
                                .frame(width: geometry.size.width / 2, height: 4)
                            Color.clear
                                .frame(width: geometry.size.width / 2, height: 4)
                        }
                    } else {
                        JourneyTravelingLine(reduceMotion: reduceMotion)
                    }
                case .pending:
                    EmptyView()
                }

                if let checkpoint {
                    ZStack {
                        if checkpointIsWaiting {
                            JourneyActivityRing(size: 42, reduceMotion: reduceMotion)
                        }
                        Circle().fill(Color.blue).frame(width: 28, height: 28)
                        Image(systemName: checkpoint == .authentication ? "key.fill" : "checkmark.shield.fill")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                    .transition(.scale(scale: 0.65).combined(with: .opacity))
                    .accessibilityLabel(
                        checkpoint == .authentication
                            ? Text("Authentication required") : Text("Host key confirmation required"))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 56)
        .animation(reduceMotion ? nil : Motion.panel, value: checkpoint)
    }
}

private struct JourneyTravelingLine: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            HStack(spacing: 0) {
                Rectangle().fill(Color.blue).frame(width: 34, height: 4)
                Spacer(minLength: 0)
            }
        } else {
            TimelineView(.animation) { timeline in
                GeometryReader { proxy in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let progress = 0.16 + 0.64 * ((sin(time * 2.4) + 1) / 2)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.55), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(18, proxy.size.width * progress), height: 4)
                }
                .frame(height: 4)
            }
        }
    }
}

private struct JourneyActivityRing: View {
    let size: CGFloat
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            Circle().stroke(Color.blue.opacity(0.45), lineWidth: 4)
                .frame(width: size, height: size)
        } else {
            TimelineView(.animation) { timeline in
                let rotation =
                    timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.25) / 1.25 * 360
                Circle()
                    .trim(from: 0.06, to: 0.78)
                    .stroke(
                        AngularGradient(
                            colors: [.blue.opacity(0.15), .blue, .blue.opacity(0.32)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation))
                    .frame(width: size, height: size)
            }
        }
    }
}

private struct JourneyAuthenticationCard: View {
    let prompt: SSHAuthenticationPrompt
    let submit: (Identity.ID?, String, String?, String?, SSHKeyRef.ID?, Bool) -> Void
    let cancel: () -> Void

    @Environment(AppModel.self) private var app
    @State private var identityID: Identity.ID?
    @State private var username: String
    @State private var password = ""
    @State private var passphrase = ""
    @State private var keyID: SSHKeyRef.ID?
    @FocusState private var focusedField: Field?

    private enum Field { case username, password, passphrase }

    init(
        prompt: SSHAuthenticationPrompt,
        submit: @escaping (Identity.ID?, String, String?, String?, SSHKeyRef.ID?, Bool) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.submit = submit
        self.cancel = cancel
        _identityID = State(initialValue: prompt.selectedIdentityID)
        _username = State(initialValue: prompt.username)
        _keyID = State(initialValue: prompt.selectedKeyID)
    }

    private var needsPassphrase: Bool {
        prompt.requiresPassphrase
    }

    private var canContinue: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsPassphrase || !passphrase.isEmpty)
    }

    private var title: LocalizedStringKey {
        if needsPassphrase { return "Passphrase required" }
        return prompt.mode == .localIdentity
            ? "Identity required" : "Authentication required"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    .font(.headline)
                    Text(prompt.host.displayAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "key.fill").font(.title2).foregroundStyle(.blue)
            }

            if let message = prompt.failureMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if needsPassphrase {
                    GridRow {
                        Text("Passphrase").foregroundStyle(.secondary)
                        SecureField("Required for this connection", text: $passphrase)
                            .focused($focusedField, equals: .passphrase)
                    }
                } else {
                    GridRow {
                        Text("Identity").foregroundStyle(.secondary)
                        fullWidthMenu(title: identityLabel) {
                            Button {
                                identitySelection.wrappedValue = nil
                            } label: {
                                selectionMenuLabel(
                                    String(localized: "Custom"), selected: identityID == nil
                                )
                            }
                            if !app.hosts.identities.isEmpty { Divider() }
                            ForEach(app.hosts.identities) { identity in
                                Button {
                                    identitySelection.wrappedValue = identity.id
                                } label: {
                                    selectionMenuLabel(
                                        "\(identity.name) · \(identity.username)",
                                        selected: identityID == identity.id
                                    )
                                }
                            }
                        }
                    }
                    if identityID == nil {
                        GridRow {
                            Text("Username").foregroundStyle(.secondary)
                            TextField("Username", text: usernameInput)
                                .focused($focusedField, equals: .username)
                        }
                        GridRow {
                            Text("Password").foregroundStyle(.secondary)
                            SecureField("Optional", text: passwordInput)
                                .focused($focusedField, equals: .password)
                        }
                        GridRow {
                            Text("Key").foregroundStyle(.secondary)
                            fullWidthMenu(title: keyLabel) {
                                Button {
                                    keySelection.wrappedValue = nil
                                } label: {
                                    selectionMenuLabel(
                                        String(localized: "None"), selected: keyID == nil
                                    )
                                }
                                if !app.hosts.keys.isEmpty { Divider() }
                                ForEach(app.hosts.keys) { key in
                                    Button {
                                        keySelection.wrappedValue = key.id
                                    } label: {
                                        selectionMenuLabel(
                                            key.label, selected: keyID == key.id
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if needsPassphrase {
                    Button("Continue") { commit(save: false) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                } else {
                    Button("Continue") { commit(save: false) }.disabled(!canContinue)
                    Button("Save and Continue") { commit(save: true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.7)) }
        .onAppear {
            if identityID != nil, selectedIdentity == nil { identityID = nil }
            updateFocusForRequirement()
        }
    }

    private func updateFocusForRequirement() {
        if needsPassphrase {
            focusedField = .passphrase
        } else if identityID == nil {
            focusedField = username.isEmpty ? .username : .password
        } else {
            focusedField = nil
        }
    }

    private func commit(save: Bool) {
        submit(
            identityID, username, password.isEmpty ? nil : password,
            passphrase.isEmpty ? nil : passphrase, keyID, save
        )
    }

    private var selectedIdentity: Identity? {
        identityID.flatMap { app.hosts.identity($0) }
    }

    private var identityLabel: String {
        selectedIdentity.map { "\($0.name) · \($0.username)" }
            ?? String(localized: "Custom")
    }

    private var keyLabel: String {
        keyID.flatMap { app.hosts.key($0) }?.label ?? String(localized: "None")
    }

    private func fullWidthMenu<Content: View>(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { geometry in
            Menu(content: content) {
                HStack(spacing: 8) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(width: geometry.size.width, height: 28)
                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.055))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(width: geometry.size.width, height: 28)
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
    }

    @ViewBuilder
    private func selectionMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var identitySelection: Binding<Identity.ID?> {
        Binding {
            identityID
        } set: { id in
            identityID = id
            guard let identity = id.flatMap({ app.hosts.identity($0) }) else { return }
            username = identity.username
            password = ""
            passphrase = ""
            keyID = identity.keyID
        }
    }

    private var usernameInput: Binding<String> {
        Binding {
            username
        } set: { value in
            username = value
            if value != selectedIdentity?.username { identityID = nil }
        }
    }

    private var passwordInput: Binding<String> {
        Binding {
            password
        } set: { value in
            password = value
            if !value.isEmpty { identityID = nil }
        }
    }

    private var keySelection: Binding<SSHKeyRef.ID?> {
        Binding {
            keyID
        } set: { value in
            keyID = value
            if value != selectedIdentity?.keyID { identityID = nil }
            passphrase = ""
        }
    }
}

private struct JourneyHostKeyCard: View {
    let prompt: SSHHostKeyPrompt
    let proceed: () -> Void
    let trust: () -> Void
    let deny: () -> Void

    private var observation: SSHHostKeyObservation { prompt.observation }

    private var isAdditionalKey: Bool {
        if case .additionalKey = prompt.kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                isAdditionalKey ? "Unrecognized additional host key" : "Verify host identity",
                systemImage: isAdditionalKey
                    ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
            )
            .font(.headline)
            .foregroundStyle(isAdditionalKey ? .orange : .blue)
            Text(explanation)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(observation.algorithm.displayName).font(.caption).foregroundStyle(.secondary)
                Text(observation.fingerprint).font(.body.monospaced()).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.65), in: .rect(cornerRadius: 8))
            HStack {
                Button("Deny", role: .destructive, action: deny).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue", action: proceed)
                    .help("Continue once without saving this host key")
                Button("Trust and Continue", action: trust)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.7)) }
    }
    private var explanation: String {
        switch prompt.kind {
        case .firstUse:
            String(
                localized:
                    "No trusted key is saved for \(observation.hostname). Confirm this fingerprint before continuing."
            )
        case .additionalKey(let trustedKeyCount):
            String(
                localized:
                    "This key is not among the \(trustedKeyCount) trusted keys saved for \(observation.hostname). Verify it carefully before adding it."
            )
        }
    }
}

private struct JourneyFailureCard: View {
    let message: String
    let retry: () -> Void
    let cancel: () -> Void
    let copyLogs: () -> Void
    let askAI: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connection Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.red)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Copy Logs", action: copyLogs)
                if let askAI { Button("Ask AI", action: askAI) }
                Spacer()
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .background(Color.red.opacity(0.065), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.red.opacity(0.3)) }
    }
}
