import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

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
    /// Connection cancellation removes the pane instead of revealing the
    /// retained pre-journey terminal surface underneath it.
    let closePane: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @TerminalAppearanceSettings private var terminalAppearance
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var terminalFocused: Bool
    @State private var pendingUploadSession: SFTPSessionModel?
    @State private var pendingUploadItemCount = 0
    @State private var uploadConflictPresented = false
    @State private var uploadNotice: WorkspaceUploadNotice?
    @State private var uploadNoticeTask: Task<Void, Never>?
    @State private var uploadPreparationTask: Task<Void, Never>?
    @State private var uploadPreparationID: UUID?
    @State private var uploadEnqueueTask: Task<Void, Never>?

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
            .animation(Motion.panel, value: uploadNotice)
            .background(terminalAppearance.background)
            .onAppear {
                // The mounted view is the final source of truth after any drag,
                // merge, detach, or SwiftUI tree rebuild. Reassert the relationship
                // here so a stale layout callback cannot leave live keystrokes on a
                // sshSession whose router was cleared while it moved.
                sshSession.inputRouter = workspace
                terminalFocused = requestsFocus
                TerminalFontCatalog.shared.refresh()
                sshSession.terminalState.applyPreferences(terminalAppearance.preferences, font: terminalAppearance.font)
                sshSession.connectIfNeeded(using: app.hostLibrary)
                if requestsFocus { sshSession.requestTerminalFocus() }
            }
            .onChange(of: requestsFocus) { _, focused in
                terminalFocused = focused
                if focused { sshSession.requestTerminalFocus() }
            }
            .onChange(of: externalFileDrop?.id) {
                guard let externalFileDrop else { return }
                _ = receiveDroppedURLs(externalFileDrop.urls)
            }
            .onChange(of: sshSession.connectionAttemptID) { cancelPendingUpload() }
            .onDisappear {
                terminalFocused = false
                cancelPendingUpload()
            }
            .onChange(of: terminalAppearance) { _, appearance in
                sshSession.terminalState.applyPreferences(appearance.preferences, font: appearance.font)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { TerminalFontCatalog.shared.refresh() }
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
    }

    @ViewBuilder
    private var uploadDecoration: some View {
        if let uploadNotice {
            TerminalUploadOverlay(notice: uploadNotice, homeResolution: sshSession.homeResolution)
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
                    sshSession.continueWithTemporaryHostKey($0)
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
                stopReconnecting: sshSession.stopReconnecting,
                keyboardAuthentication: sshSession.connection.keyboardAuthentication
            )
        }
    }

    private var uploadTargetProblem: String? {
        TerminalUploadAvailability.problem(
            isConnected: sshSession.status == .connected,
            hasTransferConfiguration: sshSession.transferConfiguration != nil,
            isWorkingDirectoryPending: sshSession.homeResolution.isPending,
            workingDirectory: sshSession.workingDirectory
        )
    }

    private var uploadConflictTitle: String {
        let count = pendingUploadSession?.conflictCount ?? 0
        return count == 1
            ? String(localized: "1 item already exists")
            : String(localized: "\(count) items already exist")
    }

    private func receiveDroppedURLs(_ urls: [URL]) -> Bool {
        // Only this terminal convenience is Pro. SFTPBrowserView keeps its own
        // upload flow and remains free.
        guard app.proAccess.require(.terminalFileUpload) else { return false }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        cancelPendingUpload()
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
        let generation = sshSession.connectionAttemptID
        let preparationID = UUID()
        uploadPreparationID = preparationID
        pendingUploadItemCount = files.count
        uploadNotice = .preparing(destination)

        uploadPreparationTask = Task {
            defer {
                if uploadPreparationID == preparationID {
                    uploadPreparationTask = nil
                    uploadPreparationID = nil
                }
            }
            var connectedClient: (any SFTPClientProtocol)?
            do {
                let client = try await app.connections.connectSFTP(
                    using: SSHConnectionRequest(configuration: configuration, interactionPolicy: .forbidden),
                    progress: nil
                )
                connectedClient = client
                try Task.checkCancellation()
                guard sshSession.connectionAttemptID == generation else { throw CancellationError() }
                let uploadSession = SFTPSessionModel(
                    hostID: sshSession.hostID,
                    initialPath: destination,
                    client: client,
                    configuration: configuration,
                    wasOpenedSilently: true,
                    homeResolution: sshSession.homeResolution
                )
                await uploadSession.prepareUpload(files)
                try Task.checkCancellation()
                guard sshSession.connectionAttemptID == generation else { throw CancellationError() }
                if let error = uploadSession.operationError {
                    uploadSession.disconnect()
                    showUploadNotice(.rejected(error))
                    return
                }
                guard uploadSession.hasPendingBatch else {
                    uploadSession.disconnect()
                    showUploadNotice(.rejected(String(localized: "No uploadable files were found.")))
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
            } catch is CancellationError {
                await connectedClient?.disconnect()
                guard uploadPreparationID == preparationID else { return }
                uploadNotice = nil
            } catch {
                await connectedClient?.disconnect()
                guard uploadPreparationID == preparationID,
                    sshSession.connectionAttemptID == generation
                else { return }
                showUploadNotice(.rejected(error.localizedDescription))
            }
        }
        return true
    }

    private func enqueuePendingUpload(_ policy: TransferConflictPolicy) {
        guard let uploadSession = pendingUploadSession else { return }
        let itemCount = pendingUploadItemCount
        let destination = uploadSession.path
        let generation = sshSession.connectionAttemptID
        uploadConflictPresented = false
        uploadEnqueueTask = Task {
            await uploadSession.enqueuePending(
                policy: policy,
                coordinator: app.sftpTransfers
            )
            let error = uploadSession.operationError
            uploadSession.disconnect()
            guard !Task.isCancelled, pendingUploadSession === uploadSession,
                sshSession.connectionAttemptID == generation
            else { return }
            uploadEnqueueTask = nil
            pendingUploadSession = nil
            pendingUploadItemCount = 0
            if let error {
                showUploadNotice(.rejected(error))
            } else {
                showUploadNotice(.queued(itemCount, destination))
            }
        }
    }

    private func cancelPendingUpload() {
        uploadPreparationTask?.cancel()
        uploadPreparationTask = nil
        uploadPreparationID = nil
        uploadEnqueueTask?.cancel()
        uploadEnqueueTask = nil
        uploadNoticeTask?.cancel()
        uploadNoticeTask = nil
        uploadNotice = nil
        uploadConflictPresented = false
        pendingUploadItemCount = 0
        guard let uploadSession = pendingUploadSession else { return }
        uploadSession.cancelPendingBatch()
        uploadSession.disconnect()
        pendingUploadSession = nil
    }

    private func showUploadNotice(_ notice: WorkspaceUploadNotice) {
        uploadNoticeTask?.cancel()
        uploadNotice = notice
        uploadNoticeTask = Task {
            try? await Task.sleep(for: .seconds(notice.isRejected ? 3 : 2))
            guard !Task.isCancelled, uploadNotice == notice else { return }
            uploadNotice = nil
            uploadNoticeTask = nil
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
        conversation.attach(
            ContextChip(
                kind: .output,
                label: String(localized: "Connection error"),
                content: String(log.suffix(4_000))
            ))
        conversation.composer.draft = String(
            localized: "SSH connection failed: \(message). What should I check?"
        )
        window.closeAssistantInSidebar()
        window.showAssistant()
    }
}

private struct TerminalUploadOverlay: View {
    let notice: WorkspaceUploadNotice
    let homeResolution: RemoteHomeResolutionState

    var body: some View {
        VStack(spacing: Metrics.Space.s) {
            symbol
            Text(notice.title).font(.headline)
            Text(notice.detail(home: homeResolution))
                .font(notice.isRejected ? .caption : .caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(notice.isRejected ? .tail : .middle)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Metrics.Space.xl)
        .padding(.vertical, Metrics.Space.l)
        .termindTransientOverlaySurface()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var symbol: some View {
        switch notice {
        case .preparing:
            ProgressView().controlSize(.small)
        case .queued, .rejected:
            Image(systemName: notice.symbol ?? "")
                .font(.title2)
                .foregroundStyle(notice.isRejected ? .orange : .green)
        }
    }
}
