// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

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
    let externalRemoteDrop: SFTPRemoteDropRequest?
    /// Connection cancellation removes the pane instead of revealing the
    /// retained pre-journey terminal surface underneath it.
    let closePane: () -> Void

    @AppStorage(DesktopSettingsKey.showStatusBar) private var showsStatusBar = true
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var terminalFocused: Bool
    @State private var uploadConflictPresented = false
    @State private var uploadBindingID: UUID?
    @State private var sftpBindingID: UUID?

    private var uploads: TerminalUploadModel { sshSession.terminalUpload }
    private var showsJourney: Bool {
        sshSession.connectionJourney.isPresented || sshSession.sessionPersistence.prompt != nil
    }

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
            .opacity(showsJourney ? 0 : 1)
            .allowsHitTesting(!showsJourney)
            .accessibilityHidden(showsJourney)
            .desktopTerminalChrome(state: sshSession.terminalState)
            .overlay(alignment: .bottom) { uploadDecoration }
            .overlay { connectionJourney }
            .animation(Motion.panel, value: uploads.notice)
            .onAppear {
                // The mounted view is the final source of truth after any drag,
                // merge, detach, or SwiftUI tree rebuild. Reassert the relationship
                // here so a stale layout callback cannot leave live keystrokes on a
                // sshSession whose router was cleared while it moved.
                sshSession.inputRouter = workspace
                terminalFocused = requestsFocus && !showsJourney
                TerminalFontCatalog.shared.refresh()
                uploadBindingID = sshSession.terminalViewOwner.bindUpload(
                    action: chooseUploadFiles,
                    isAvailable: { isVisible && uploads.uploadTargetProblem == nil })
                sftpBindingID = sshSession.terminalViewOwner.bindSFTP(
                    action: { window.openCompanionSession(from: sshSession.id, placement: $0) },
                    isAvailable: { isVisible && window.canOpenCompanionSession(from: sshSession.id) })
                sshSession.connectIfNeeded(using: app.hostLibrary)
                if requestsFocus { sshSession.requestTerminalFocus() }
            }
            .onChange(of: isVisible) {
                if let sftpBindingID {
                    sshSession.terminalViewOwner.updateSFTPAvailability(
                        for: sftpBindingID,
                        isAvailable: { isVisible && window.canOpenCompanionSession(from: sshSession.id) })
                }
                guard let uploadBindingID else { return }
                sshSession.terminalViewOwner.updateUploadAvailability(
                    for: uploadBindingID, isAvailable: { isVisible && uploads.uploadTargetProblem == nil })
            }
            .onChange(of: requestsFocus) { _, focused in
                terminalFocused = focused && !showsJourney
                if focused, !showsJourney { sshSession.terminalViewOwner.requestFocus(preservingTextEditor: true) }
            }
            .onChange(of: showsJourney) { _, presented in
                terminalFocused = requestsFocus && isVisible && !presented
            }
            .onChange(of: externalFileDrop?.id) {
                guard let externalFileDrop else { return }
                uploads.receiveFiles(externalFileDrop.urls, connections: app.connections, transfers: app.sftpTransfers)
            }
            .onChange(of: externalRemoteDrop?.id) {
                guard let externalRemoteDrop else { return }
                uploads.receiveRemoteDrop(
                    externalRemoteDrop.data, connections: app.connections, transfers: app.sftpTransfers)
            }
            .onChange(of: uploads.hasConflict, initial: true) { _, hasConflict in
                uploadConflictPresented = hasConflict
            }
            .onDisappear {
                terminalFocused = false
                if let uploadBindingID { sshSession.terminalViewOwner.unbindUpload(uploadBindingID) }
                uploadBindingID = nil
                if let sftpBindingID { sshSession.terminalViewOwner.unbindSFTP(sftpBindingID) }
                sftpBindingID = nil
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { TerminalFontCatalog.shared.refresh() }
            }
            .confirmationDialog(
                uploadConflictTitle,
                isPresented: $uploadConflictPresented,
                titleVisibility: .visible
            ) {
                Button(AppStrings.SFTP.replace.swiftUIKey) { uploads.enqueue(.replace) }
                Button(AppStrings.SFTP.skipExisting.swiftUIKey) { uploads.enqueue(.skip) }
                Button(AppStrings.SFTP.keepBoth.swiftUIKey) { uploads.enqueue(.keepBoth) }
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { uploads.cancelPendingUpload() }
            } message: {
                Text(AppStrings.SFTP.applyToAllConflicts)
            }
    }

    @ViewBuilder
    private var uploadDecoration: some View {
        if let notice = uploads.notice {
            TerminalUploadOverlay(notice: notice, homeResolution: sshSession.homeResolution)
                // Above the floating status capsule, not on top of it.
                .padding(
                    .bottom,
                    Metrics.StatusBar.overlayClearance(isEnabled: showsStatusBar)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    @ViewBuilder
    private var connectionJourney: some View {
        if isVisible, sshSession.connectionJourney.isPresented || sshSession.sessionPersistence.prompt != nil {
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
                askAssistant: {
                    if case .failed(let message) = sshSession.connectionJourney.phase {
                        askAssistant(
                            about: message,
                            log: sshSession.connectionJourney.plainTextLog
                        )
                    }
                },
                reconnectState: sshSession.reconnectState,
                retryReconnectNow: sshSession.retryReconnectNow,
                stopReconnecting: sshSession.stopReconnecting,
                securityKeySigning: sshSession.connection.securityKeySigning,
                keyboardAuthentication: sshSession.connection.keyboardAuthentication,
                remoteSession: sshSession.sessionPersistence
            )
        }
    }

    private var uploadConflictTitle: String {
        String(localized: AppStrings.SFTP.existingItemsMessage(count: uploads.conflictCount))
    }

    private func chooseUploadFiles() {
        guard let target = uploads.target else { return }
        sshSession.terminalViewOwner.chooseUploadFiles { urls in
            uploads.receiveFiles(
                urls, selectedTarget: target, connections: app.connections, transfers: app.sftpTransfers)
        }
    }

    private func cancelConnection() {
        closePane()
    }

    @ViewBuilder
    private var terminalSurface: some View {
        #if canImport(AppKit)
            PersistentTerminalSurfaceView(
                state: sshSession.terminalState,
                owner: sshSession.terminalViewOwner,
                isVisible: isVisible && !showsJourney,
                requestsFocus: requestsFocus && !showsJourney
            )
        #else
            TerminalSurfaceView(context: sshSession.terminalState)
                .terminalFocused($terminalFocused)
        #endif
    }

    /// Hands the failure to the Assistant sidebar as a draft rather than sending it —
    /// the user still decides what leaves the machine.
    private func askAssistant(about message: String, log: String) {
        let conversation = window.sidebar.assistantDraft
        SSHFailureAssistantDraft.populate(conversation, message: message, log: log)
        window.closeAssistantInSidebar()
        window.showAssistant()
    }
}

@MainActor
enum SSHFailureAssistantDraft {
    static func populate(_ conversation: ConversationModel, message: String, log: String) {
        // The log rides on the chip rather than in the draft. Pasting it into
        // the editable text made the pill a label for something the user could
        // silently delete half of, and left the draft too long to read.
        conversation.attach(
            ContextChip(
                kind: .output,
                label: String(localized: AppStrings.Terminal.connectionLog),
                content: String(log.suffix(4_000))
            ))
        conversation.composer.draft = String(
            localized: AppStrings.Terminal.sshConnectionFailedWhatShouldICheckConfirmation(message)
        )
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
