import GhosttyTerminal
import SwiftUI

/// A libghostty terminal surface with Termind's connection and suggestion chrome.
struct TerminalPlaceholderView: View {
    let sshSession: SSHSessionModel
    /// The Workspace holding this pane owns broadcast input routing.
    let workspace: Workspace
    /// Hidden tabs remain mounted to preserve Ghostty's surface, but stop
    /// rendering frames until they come forward again.
    let isVisible: Bool
    /// Only the focused terminal pane in the visible tab should own keyboard
    /// focus. A split can keep several surfaces visible at once.
    let requestsFocus: Bool
    let externalFileDrop: LocalFileDropRequest?
    let isExternalFileDropTargeted: Bool
    /// Connection cancellation removes the pane instead of revealing the
    /// retained pre-journey terminal surface underneath it.
    let closePane: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsKey.terminalFontSize) private var fontSize = 12.0
    @AppStorage(SettingsKey.terminalThemeDark) private var darkTheme =
        SettingsKey.defaultTerminalThemeDark
    @AppStorage(SettingsKey.terminalThemeLight) private var lightTheme =
        SettingsKey.defaultTerminalThemeLight
    @AppStorage(SettingsKey.terminalCustomConfigurationDarkEnabled)
    private var darkCustomEnabled = false
    @AppStorage(SettingsKey.terminalCustomConfigurationLightEnabled)
    private var lightCustomEnabled = false
    @AppStorage(SettingsKey.terminalCustomConfigurationDark)
    private var darkCustomConfiguration = ""
    @AppStorage(SettingsKey.terminalCustomConfigurationLight)
    private var lightCustomConfiguration = ""
    @AppStorage(SettingsKey.terminalFontFollowTheme) private var fontFollowTheme = true
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @FocusState private var terminalFocused: Bool
    @State private var pendingUploadSession: SFTPSessionModel?
    @State private var pendingUploadItemCount = 0
    @State private var uploadConflictPresented = false
    @State private var uploadNotice: TerminalUploadNotice?
    @State private var uploadNoticeTask: Task<Void, Never>?
    @State private var uploadPreparationTask: Task<Void, Never>?
    @State private var uploadError: String?

    private var appearancePreferences: TerminalAppearancePreferences {
        TerminalAppearancePreferences(
            lightThemeName: lightTheme,
            darkThemeName: darkTheme,
            lightCustomEnabled: lightCustomEnabled,
            darkCustomEnabled: darkCustomEnabled,
            lightCustomConfiguration: lightCustomConfiguration,
            darkCustomConfiguration: darkCustomConfiguration,
            fontFollowTheme: fontFollowTheme,
            fontSize: fontSize
        )
    }

    private var terminalBackground: Color {
        let isDark = colorScheme == .dark
        return TermindTerminalThemeCatalog.background(
            themeName: isDark ? darkTheme : lightTheme,
            customEnabled: isDark ? darkCustomEnabled : lightCustomEnabled,
            customText: isDark ? darkCustomConfiguration : lightCustomConfiguration,
            isDark: isDark
        ).color
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            terminalSurface
            if sshSession.canShowInlineSuggestions, let suggestion = sshSession.inlineSuggestion {
                InlineSuggestionOverlay(
                    suggestion: suggestion,
                    sshSession: sshSession,
                    workspace: workspace
                )
                .padding(Metrics.Space.l)
                .zIndex(4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if isExternalFileDropTargeted {
                uploadTargetOverlay
                    .zIndex(8)
                    .transition(.opacity)
            } else if let uploadNotice {
                TerminalUploadOverlay(notice: uploadNotice)
                    .zIndex(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if isVisible, sshSession.connectionJourney.isPresented {
                SSHConnectionJourneyView(
                    journey: sshSession.connectionJourney,
                    authenticationPrompt: sshSession.pendingAuthentication,
                    hostKey: sshSession.pendingHostKey,
                    submitAuthentication: {
                        identityID, username, password, passphrase, keyID, save in
                        sshSession.continueAuthentication(
                            identityID: identityID, username: username, password: password,
                            passphrase: passphrase, keyID: keyID, save: save, using: app.hosts
                        )
                    },
                    continueHostKey: {
                        sshSession.continueWithTemporaryHostKey($0, using: app.hosts)
                    },
                    trustHostKey: { sshSession.trustAndConnect($0, using: app.hosts) },
                    denyHostKey: {
                        cancelConnection()
                    },
                    retry: { sshSession.connect(using: app.hosts) },
                    cancel: cancelConnection,
                    askAI: {
                        if case .failed(let message) = sshSession.connectionJourney.phase {
                            askAI(
                                about: message,
                                log: sshSession.connectionJourney.plainTextLog
                            )
                        }
                    },
                    reconnectState: sshSession.reconnectState,
                    retryReconnectNow: sshSession.retryReconnectNow,
                    stopReconnecting: sshSession.stopReconnecting
                )
                .zIndex(10)
            }
        }
        .animation(Motion.panel, value: sshSession.inlineSuggestion)
        .animation(Motion.panel, value: sshSession.find.isPresented)
        .animation(
            Motion.tabSwitch,
            value: isExternalFileDropTargeted
        )
        .animation(Motion.panel, value: uploadNotice)
        .background(terminalBackground)
        .overlay(alignment: .top) { terminalChrome }
        .onAppear {
            // The mounted view is the final source of truth after any drag,
            // merge, detach, or SwiftUI tree rebuild. Reassert the relationship
            // here so a stale layout callback cannot leave live keystrokes on a
            // sshSession whose router was cleared while it moved.
            sshSession.inputRouter = workspace
            sshSession.terminalState.isSurfaceVisible = isVisible
            terminalFocused = requestsFocus
            sshSession.applyAppearance(appearancePreferences)
            if sshSession.status == .connecting { sshSession.connect(using: app.hosts) }
            if requestsFocus { sshSession.requestTerminalFocus() }
        }
        .onChange(of: isVisible) { _, visible in
            sshSession.terminalState.isSurfaceVisible = visible
        }
        .onChange(of: requestsFocus) { _, focused in
            terminalFocused = focused
            if focused { sshSession.requestTerminalFocus() }
        }
        .onChange(of: externalFileDrop?.id) {
            guard let externalFileDrop else { return }
            _ = receiveDroppedURLs(externalFileDrop.urls)
        }
        .onDisappear {
            sshSession.terminalState.isSurfaceVisible = false
            terminalFocused = false
            uploadNoticeTask?.cancel()
            uploadPreparationTask?.cancel()
            cancelPendingUpload()
        }
        .onChange(of: appearancePreferences) { _, preferences in
            sshSession.applyAppearance(preferences)
        }
        .confirmationDialog(
            uploadConflictTitle,
            isPresented: $uploadConflictPresented,
            titleVisibility: .visible
        ) {
            Button("Replace") { enqueuePendingUpload(.replace) }
            Button("Skip Existing") { enqueuePendingUpload(.skip) }
            Button("Keep Both") { enqueuePendingUpload(.keepBoth) }
            Button("Cancel", role: .cancel) { cancelPendingUpload() }
        } message: {
            Text("Use this choice for all conflicts in this batch.")
        }
        .alert(
            "Upload Failed",
            isPresented: Binding(
                get: { uploadError != nil },
                set: { if !$0 { uploadError = nil } }
            )
        ) {
            Button("OK") { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
    }

    private var uploadTargetProblem: String? {
        guard sshSession.status == .connected,
            sshSession.transferConfiguration != nil
        else {
            return String(localized: "The SSH session is not ready for file transfer.")
        }
        guard let directory = sshSession.workingDirectory, !directory.isEmpty else {
            return String(
                localized: "Wait for the shell prompt to report its current directory."
            )
        }
        return nil
    }

    private var uploadConflictTitle: String {
        let count = pendingUploadSession?.conflictCount ?? 0
        return count == 1
            ? String(localized: "1 item already exists")
            : String(localized: "\(count) items already exist")
    }

    @ViewBuilder
    private var uploadTargetOverlay: some View {
        if let problem = uploadTargetProblem {
            TerminalUploadTargetOverlay(
                title: String(localized: "Can't Upload Here"),
                detail: problem,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        } else {
            TerminalUploadTargetOverlay(
                title: String(localized: "Upload to \(uploadHostName)"),
                detail: RemotePath.normalized(sshSession.workingDirectory ?? "/"),
                systemImage: "arrow.up.doc.fill",
                tint: .accentColor
            )
        }
    }

    private var uploadHostName: String {
        app.hosts.host(sshSession.hostID)?.name ?? sshSession.title
    }

    private func receiveDroppedURLs(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        guard uploadTargetProblem == nil,
            let configuration = sshSession.transferConfiguration,
            let workingDirectory = sshSession.workingDirectory
        else {
            showUploadNotice(
                .rejected(
                    uploadTargetProblem
                        ?? String(localized: "The upload destination is unavailable.")
                )
            )
            return false
        }

        let destination = RemotePath.normalized(workingDirectory)
        pendingUploadItemCount = files.count
        uploadNoticeTask?.cancel()
        uploadPreparationTask?.cancel()
        uploadNotice = .preparing(destination)

        uploadPreparationTask = Task {
            var connectedClient: (any SFTPClientProtocol)?
            do {
                let client = try await app.connections.connectSFTP(
                    using: configuration, progress: nil
                )
                connectedClient = client
                try Task.checkCancellation()
                let uploadSession = SFTPSessionModel(
                    hostID: sshSession.hostID,
                    initialPath: destination,
                    client: client,
                    configuration: configuration
                )
                await uploadSession.prepareUpload(files)
                try Task.checkCancellation()
                if let error = uploadSession.operationError {
                    uploadSession.disconnect()
                    uploadNotice = nil
                    uploadError = error
                    return
                }
                guard uploadSession.pendingBatch != nil else {
                    uploadSession.disconnect()
                    uploadNotice = nil
                    uploadError = String(localized: "No uploadable files were found.")
                    return
                }
                pendingUploadSession = uploadSession
                connectedClient = nil
                if uploadSession.conflictCount > 0 {
                    uploadNotice = nil
                    uploadConflictPresented = true
                } else {
                    enqueuePendingUpload(.replace)
                }
                uploadPreparationTask = nil
            } catch is CancellationError {
                await connectedClient?.disconnect()
                uploadNotice = nil
                uploadPreparationTask = nil
            } catch {
                await connectedClient?.disconnect()
                uploadNotice = nil
                uploadError = error.localizedDescription
                uploadPreparationTask = nil
            }
        }
        return true
    }

    private func enqueuePendingUpload(_ policy: TransferConflictPolicy) {
        guard let uploadSession = pendingUploadSession else { return }
        let itemCount = pendingUploadItemCount
        let destination = uploadSession.path
        uploadConflictPresented = false
        Task {
            await uploadSession.enqueuePending(
                policy: policy,
                coordinator: app.sftpTransfers
            )
            let error = uploadSession.operationError
            uploadSession.disconnect()
            pendingUploadSession = nil
            pendingUploadItemCount = 0
            if let error {
                uploadNotice = nil
                uploadError = error
            } else {
                showUploadNotice(.queued(itemCount, destination))
            }
        }
    }

    private func cancelPendingUpload() {
        uploadPreparationTask?.cancel()
        uploadPreparationTask = nil
        guard let uploadSession = pendingUploadSession else { return }
        uploadConflictPresented = false
        uploadSession.pendingBatch = nil
        uploadSession.disconnect()
        pendingUploadSession = nil
        pendingUploadItemCount = 0
        uploadNotice = nil
    }

    private func showUploadNotice(_ notice: TerminalUploadNotice) {
        uploadNoticeTask?.cancel()
        uploadNotice = notice
        uploadNoticeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, uploadNotice == notice else { return }
            uploadNotice = nil
        }
    }

    private func cancelConnection() {
        sshSession.disconnect()
        closePane()
    }

    /// Find remains terminal chrome; connection state belongs exclusively to
    /// the journey overlay above. There is intentionally no legacy disconnected
    /// banner to reveal when a journey ends.
    private var terminalChrome: some View {
        VStack(spacing: 0) {
            if sshSession.find.isPresented {
                HStack {
                    Spacer(minLength: Metrics.Space.l)
                    TerminalFindBar(sshSession: sshSession, isPaneFocused: requestsFocus)
                }
                .padding(.top, Metrics.Space.m)
                .padding(.horizontal, Metrics.Space.m)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var terminalSurface: some View {
        #if canImport(AppKit)
            PersistentTerminalSurfaceView(
                state: sshSession.terminalState,
                owner: sshSession.terminalViewOwner,
                isVisible: isVisible,
                requestsFocus: requestsFocus
            )
        #else
            TerminalSurfaceView(context: sshSession.terminalState)
                .terminalFocused($terminalFocused)
        #endif
    }

    /// Hands the failure to the Assistant sidebar as a draft rather than sending it —
    /// the user still decides what leaves the machine.
    private func askAI(about message: String, log: String) {
        let conversation = window.sidebar.assistantDraft
        conversation.addChip(
            ContextChip(kind: .output, label: String(localized: "Connection error"), approximateTokens: 40)
        )
        let excerpt = String(log.suffix(4_000))
        conversation.draft = String(
            localized:
                "SSH connection failed: \(message). What should I check?\n\nConnection log:\n\(excerpt)"
        )
        window.closeAssistantInSidebar()
        window.showAssistant()
    }
}

private enum TerminalUploadNotice: Equatable {
    case preparing(String)
    case queued(Int, String)
    case rejected(String)
}

private struct TerminalUploadTargetOverlay: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        ZStack {
            tint.opacity(0.08)
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
                .padding(Metrics.Space.m)

            VStack(spacing: Metrics.Space.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Metrics.Space.xl)
            .padding(.vertical, Metrics.Space.l)
            .background(.regularMaterial, in: .rect(cornerRadius: Metrics.Radius.large))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.large)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        }
        .allowsHitTesting(false)
    }
}

private struct TerminalUploadOverlay: View {
    let notice: TerminalUploadNotice

    var body: some View {
        VStack(spacing: Metrics.Space.s) {
            symbol
            Text(title).font(.headline)
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Metrics.Space.xl)
        .padding(.vertical, Metrics.Space.l)
        .background(.regularMaterial, in: .rect(cornerRadius: Metrics.Radius.large))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var symbol: some View {
        switch notice {
        case .preparing:
            ProgressView().controlSize(.small)
        case .queued:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .rejected:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch notice {
        case .preparing: String(localized: "Preparing upload…")
        case .queued(let count, _):
            count == 1
                ? String(localized: "Added 1 item to Transfers")
                : String(localized: "Added \(count) items to Transfers")
        case .rejected: String(localized: "Can't upload here")
        }
    }

    private var detail: String {
        switch notice {
        case .preparing(let path), .queued(_, let path): path
        case .rejected(let reason): reason
        }
    }
}

/// A compact, industrial find widget: one input and the three actions users scan
/// for in VS Code. Ghostty draws the matches underneath; this view owns only the
/// query, navigation intents and focus handoff.
private struct TerminalFindBar: View {
    let sshSession: SSHSessionModel
    let isPaneFocused: Bool

    @FocusState private var fieldFocused: Bool

    private var query: Binding<String> {
        Binding(
            get: { sshSession.find.query },
            set: { sshSession.updateFindQuery($0) }
        )
    }

    private var canNavigate: Bool { !sshSession.find.query.isEmpty }

    var body: some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Find", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 184)
                .focused($fieldFocused)
                .onKeyPress(.return, phases: .down) { press in
                    let nonShiftModifiers: EventModifiers = [.command, .control, .option]
                    guard press.modifiers.intersection(nonShiftModifiers).isEmpty else {
                        return .ignored
                    }
                    sshSession.navigateFind(press.modifiers.contains(.shift) ? .next : .previous)
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    sshSession.dismissFind()
                    return .handled
                }
                .accessibilityLabel(Text("Find in terminal"))

            Divider().frame(height: 16)

            findButton(
                systemName: "chevron.up",
                label: "Previous match",
                help: "Previous match — Return, ⇧⌘G, ⇧F3",
                action: { sshSession.navigateFind(.previous) }
            )
            .disabled(!canNavigate)

            findButton(
                systemName: "chevron.down",
                label: "Next match",
                help: "Next match — ⇧Return, ⌘G, F3",
                action: { sshSession.navigateFind(.next) }
            )
            .disabled(!canNavigate)

            findButton(
                systemName: "xmark",
                label: "Close find",
                help: "Close find — Esc",
                action: sshSession.dismissFind
            )
        }
        .padding(.leading, Metrics.Space.m)
        .padding(.trailing, Metrics.Space.xs)
        .padding(.vertical, Metrics.Space.xs)
        .background(.regularMaterial, in: .rect(cornerRadius: Metrics.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.medium)
                .strokeBorder(.separator.opacity(0.75), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .onAppear {
            // Rebuilding a split can recreate every open find bar. Only the
            // focused pane may claim the window's first responder at that time.
            if isPaneFocused { focusFieldAfterInsertion() }
        }
        .onChange(of: sshSession.find.focusRequest) { focusFieldAfterInsertion() }
        .onExitCommand { sshSession.dismissFind() }
        .accessibilityElement(children: .contain)
    }

    /// SwiftUI can run `onAppear` before the newly inserted NSTextField has a
    /// window. Defer one main-loop turn so ⌘F reliably takes focus away from the
    /// native Ghostty surface; the same path also makes a second ⌘F refocus it.
    private func focusFieldAfterInsertion() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func findButton(
        systemName: String,
        label: LocalizedStringKey,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text(label))
        .help(Text(help))
    }
}
