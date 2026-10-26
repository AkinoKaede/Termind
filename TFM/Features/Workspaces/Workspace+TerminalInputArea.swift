// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import TermindApplication
import TermindPresentation

extension Workspace {
    func insertSidebarText(_ text: String, in window: NSWindow?) {
        let pane = focusedPane
        guard pane.sshSession?.status.isLive == true || pane.telnetSession?.status.isLive == true else { return }
        if pane.presentsTerminalCanvas,
            TerminalInputTextView.insertInFocusedEditor(text, for: pane.terminalInputArea, in: window)
        {
            return
        }
        deliverToFocusedTerminal(text)
    }

    func submitInputArea(_ text: String, from pane: Pane) throws {
        guard layout.pane(pane.id) === pane else { throw TerminalInputAreaError.unavailable }
        switch pane.content {
        case .sshSession(let origin):
            let targets = broadcastsInput && canBroadcast ? broadcastTargets : [origin]
            // Preflight the whole group before writing, so a rejected target
            // cannot leave the draft available for an accidental partial retry.
            for target in targets { try target.validateInputAreaSubmission() }
            deliver(text, from: origin, submit: true)
        case .telnetSession(let session):
            try session.validateInputAreaSubmission()
            session.insert(text, submit: true)
        case .serialSession(let session):
            try session.submitInputArea(text)
        case .sftpChannel, .empty:
            throw TerminalInputAreaError.unavailable
        }
    }

    func generateInputAreaCommand(
        from pane: Pane,
        using controller: any CommandGenerating,
        readViewport: (SSHSessionModel) -> String? = { $0.terminalViewOwner.readViewportText() }
    ) {
        let input = pane.terminalInputArea
        guard layout.pane(pane.id) === pane, !input.isGenerating, !input.isTranscribing, input.hasContent
        else { return }
        input.mode = .commandGenerator
        input.requestEditorFocus()
        guard let session = pane.sshSession, pane.presentsTerminalCanvas, session.status == .connected
        else {
            input.failGeneration(String(localized: AppStrings.TerminalInput.generatorRequiresSSH))
            return
        }
        do {
            try session.validateInputAreaSubmission()
        } catch {
            input.failGeneration(error.localizedDescription)
            return
        }
        let revision = session.commandGeneratorRevision
        let draft = input.draft
        let context = CommandGeneratorContext(
            draft: draft, shell: session.integratedShell ?? "", cwd: session.workingDirectory ?? "",
            remoteSystemInfo: session.remoteSystemInfo,
            viewport: readViewport(session).map { .init(text: $0) }
        )
        input.generate(context: context, using: controller) { [weak self, weak pane, weak session] in
            guard let self, let pane, let session else { return false }
            return self.layout.pane(pane.id) === pane && pane.sshSession === session
                && pane.presentsTerminalCanvas && (try? session.validateInputAreaSubmission()) != nil
                && session.commandGeneratorRevision == revision
                && pane.terminalInputArea.mode == .commandGenerator && pane.terminalInputArea.draft == draft
        }
    }
}
