import GhosttyTerminal
import SwiftUI

/// A libghostty terminal surface with Termind's connection and suggestion chrome.
struct TerminalPlaceholderView: View {
    let sshSession: SSHSessionModel
    /// The Workspace holding this pane owns broadcast input routing.
    let workspace: Workspace
    /// Hidden workspaces remain mounted to preserve Ghostty's surface, but stop
    /// rendering frames until they come forward again.
    let isVisible: Bool
    /// Only the focused terminal pane in the visible workspace should own keyboard
    /// focus. A split can keep several surfaces visible at once.
    let requestsFocus: Bool
    let externalFileDrop: LocalFileDropRequest?
    let isExternalFileDropTargeted: Bool
    /// Connection cancellation removes the pane instead of revealing the
    /// retained pre-journey terminal surface underneath it.
    let closePane: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @TerminalAppearanceSettings private var terminalAppearance
    @FocusState private var terminalFocused: Bool
    @State private var pendingUploadSession: SFTPSessionModel?
    @State private var pendingUploadItemCount = 0
    @State private var uploadConflictPresented = false
    @State private var uploadNotice: TerminalUploadNotice?
    @State private var uploadNoticeTask: Task<Void, Never>?
    @State private var uploadPreparationTask: Task<Void, Never>?
    @State private var uploadError: String?

    /// The surface decides the pane's size; everything else is an overlay.
    ///
    /// These used to be siblings in a `ZStack`, which makes a stack as tall as
    /// its tallest child — and the journey has a minimum height. In a short pane
    /// it reported more than it was offered (measured: 512 for a 440 proposal),
    /// `.frame(maxHeight: .infinity)` passed that up rather than clamping it,
    /// and the oversize climbed the whole chain and came back down as a larger
    /// proposal, so the journey was laid out taller than the pane and centred —
    /// which is what threw it upward at the moment a connection settled. An
    /// overlay is proposed the base's size and never reports one, so the
    /// terminal alone answers for the pane.
    var body: some View {
        terminalSurface
            .overlay(alignment: .bottom) { uploadDecoration }
            .overlay { connectionJourney }
        .animation(
            Motion.workspaceSwitch,
            value: isExternalFileDropTargeted
        )
        .animation(Motion.panel, value: uploadNotice)
        .background(terminalAppearance.background)
        .onAppear {
            // The mounted view is the final source of truth after any drag,
            // merge, detach, or SwiftUI tree rebuild. Reassert the relationship
            // here so a stale layout callback cannot leave live keystrokes on a
            // sshSession whose router was cleared while it moved.
            sshSession.inputRouter = workspace
            sshSession.terminalState.isSurfaceVisible = isVisible
            terminalFocused = requestsFocus
            sshSession.applyAppearance(terminalAppearance.preferences)
            if sshSession.status == .connecting { sshSession.connect(using: app.hostLibrary) }
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
        .onChange(of: terminalAppearance.preferences) { _, preferences in
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

    @ViewBuilder
    private var uploadDecoration: some View {
        if isExternalFileDropTargeted {
            uploadTargetOverlay
                .transition(.opacity)
        } else if let uploadNotice {
            TerminalUploadOverlay(notice: uploadNotice)
                // Above the floating status capsule, not on top of it.
                .padding(.bottom, Metrics.StatusBar.overlayClearance)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    @ViewBuilder
    private var connectionJourney: some View {
        if isVisible, sshSession.connectionJourney.isPresented {
            ConnectionJourneyView(
                journey: sshSession.connectionJourney,
                authenticationPrompt: sshSession.pendingAuthentication,
                hostKey: sshSession.pendingHostKey,
                submitAuthentication: {
                    identityID, username, password, passphrase, keyID, save in
                    sshSession.continueAuthentication(
                        identityID: identityID, username: username, password: password,
                        passphrase: passphrase, keyID: keyID, save: save, using: app.hostLibrary
                    )
                },
                continueHostKey: {
                    sshSession.continueWithTemporaryHostKey($0, using: app.hostLibrary)
                },
                trustHostKey: { sshSession.trustAndConnect($0, using: app.hostLibrary) },
                denyHostKey: {
                    cancelConnection()
                },
                retry: { sshSession.connect(using: app.hostLibrary) },
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
        }
    }

    private var uploadTargetProblem: String? {
        guard sshSession.status == .connected,
            sshSession.transferConfiguration != nil
        else {
            return String(localized: "The SSH session is not ready for file transfer.")
        }
        guard !sshSession.homeResolution.isPending else {
            return String(localized: "Wait for the shell prompt to report its current directory.")
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
                detail: sshSession.displayPath(
                    RemotePath.normalized(sshSession.workingDirectory ?? "/")
                ),
                systemImage: "arrow.up.doc.fill",
                tint: .accentColor
            )
        }
    }

    private var uploadHostName: String {
        app.hostLibrary.host(sshSession.hostID)?.name ?? sshSession.title
    }

    private func receiveDroppedURLs(_ urls: [URL]) -> Bool {
        // Only this terminal convenience is Pro. SFTPBrowserView keeps its own
        // upload flow and remains free.
        guard app.proAccess.require(.terminalFileUpload) else { return false }
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
                    configuration: configuration,
                    homeResolution: sshSession.homeResolution
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
        // The log rides on the chip rather than in the draft. Pasting it into
        // the editable text made the pill a label for something the user could
        // silently delete half of, and left the draft too long to read.
        conversation.attach(ContextChip(
            kind: .output,
            label: String(localized: "Connection error"),
            content: String(log.suffix(4_000))
        ))
        conversation.draft = String(
            localized: "SSH connection failed: \(message). What should I check?"
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
            .termindGlassSurface(cornerRadius: Metrics.Radius.large)
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
        .termindGlassSurface(cornerRadius: Metrics.Radius.large)
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
