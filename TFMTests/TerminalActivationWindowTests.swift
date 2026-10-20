// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite(
    .requiresVisibleWindow, .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_TMUX_FIXTURE"] != nil))
@MainActor
struct TerminalActivationWindowTests {
    @Test(.timeLimit(.minutes(2)))
    func equallySizedWorkspacesRecoverFromParkedSizeWithoutKeyboardInput() async throws {
        let remote = try await TmuxActivationFixture.make()
        let deck = try ActivationWindowFixture(remote: remote)
        do {
            let first = deck.model.sessions[0]
            let second = deck.model.sessions[1]
            try await TmuxActivationFixture.wait {
                // Test-host launch can temporarily take focus after the window is shown.
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                deck.window.orderFrontRegardless()
                deck.window.makeMain()
                deck.window.makeKey()
                return NSApp.isActive && deck.window.isKeyWindow
            }
            try await TmuxActivationFixture.wait { first.terminalState.surfaceSize != nil }
            try deck.focus(first)
            try await deck.show(0)
            first.connect(using: deck.library)
            try await deck.waitForRuntime(first)
            try await deck.expectLayers(first, label: "first connection")
            let parked = try #require(second.terminalState.surfaceSize)

            deck.window.setContentSize(NSSize(width: 1000, height: 680))
            try await TmuxActivationFixture.wait {
                first.terminalState.surfaceSize != parked
            }
            #expect(second.terminalState.surfaceSize == parked)
            try await deck.expectLayers(first, label: "visible enlarged, hidden parked")

            // Connect the hidden workspace at its cached small viewport. The active
            // terminal keeps the correct PTY size, but tmux now chooses the hidden client.
            second.connect(using: deck.library)
            try await deck.waitForRuntime(second)
            try await remote.expectSize(columns: parked.columns, rows: parked.rows)
            #expect(!second.isTerminalActive)
            #expect(deck.window.makeFirstResponder(deck.search))
            try await TmuxActivationFixture.wait { !first.isTerminalActive }
            try await Task.sleep(for: .milliseconds(250))
            try await remote.expectSize(columns: parked.columns, rows: parked.rows)
            #expect(deck.window.firstResponder === deck.search.currentEditor())
            try deck.focus(first)
            try await deck.expectLayers(first, label: "click restores unchanged PTY")

            try await deck.show(1)
            try await deck.expectLayers(second, label: "second workspace at same visible size")
            #expect(first.terminalState.surfaceSize == second.terminalState.surfaceSize)
            for index in [0, 1, 0, 1, 0] { try await deck.show(index) }
            try await deck.expectLayers(first, label: "rapid switching")

            // An actual native key-window change, not a SwiftUI focus request.
            let other = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            other.makeKeyAndOrderFront(nil)
            try await TmuxActivationFixture.wait { !first.isTerminalActive }
            _ = try await remote.attach(columns: 40, rows: 22, integrated: false)
            try await remote.expectSize(columns: 40, rows: 22)
            deck.window.makeKeyAndOrderFront(nil)
            try await deck.expectLayers(first, label: "window reactivation")

            first.disconnect()
            first.connect(using: deck.library)
            try await deck.waitForRuntime(first)
            try await deck.expectLayers(first, label: "reconnected focused terminal")
            deck.close()
            await remote.close()
        } catch {
            let diagnostic = deck.model.sessions.map {
                "status=\($0.status), runtime=\($0.terminalContext.status), active=\($0.isTerminalActive), "
                    + "focus=\($0.terminalState.isFocused), visible=\($0.terminalState.isSurfaceVisible), "
                    + "grid=\(String(describing: $0.terminalState.surfaceSize))"
            }.joined(separator: "\n")
            Attachment.record(
                Data(
                    ("appActive=\(NSApp.isActive), key=\(deck.window.isKeyWindow), "
                        + "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"), "
                        + "responder=\(String(describing: deck.window.firstResponder))\n\(diagnostic)")
                        .utf8),
                named: "activation-failure.txt")
            deck.close()
            await remote.close()
            throw error
        }
    }
}

@MainActor @Observable
private final class ActivationDeckModel {
    let sessions: [SSHSessionModel]
    var selected = 0
    init(sessions: [SSHSessionModel]) { self.sessions = sessions }
}

private struct ActivationDeck: View {
    let model: ActivationDeckModel

    var body: some View {
        PersistentWorkspaceDeckLayout {
            ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                let active = model.selected == index
                PersistentTerminalSurfaceView(
                    state: session.terminalState, owner: session.terminalViewOwner,
                    isVisible: active, requestsFocus: active
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
                .disabled(!active)
                .zIndex(active ? 1 : 0)
                .persistentWorkspaceDeckValue(id: session.id, isActive: active)
            }
        }
    }
}

@MainActor
private final class ActivationWindowFixture {
    let remote: TmuxActivationFixture
    let library: HostLibraryModel
    let model: ActivationDeckModel
    let window: NSWindow
    let search = NSTextField()
    private let hosting: NSHostingView<ActivationDeck>

    init(remote: TmuxActivationFixture) throws {
        self.remote = remote
        let key = SSHKeyRef(
            label: "Activation fixture", publicKey: "", credentialRef: UUID().uuidString, storage: .thisDevice)
        let identity = Identity(name: "Fixture", username: "root", keyID: key.id)
        var host = TermindDomain.Host(
            name: "Activation fixture", host: "127.0.0.1", port: remote.configuration.port, identityID: identity.id)
        host.shellIntegrationMode = .enabled
        library = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [
                .init(
                    hostname: host.host, port: host.sshPort, algorithm: .ed25519,
                    fingerprint: remote.configuration.hostFingerprint)
            ])
        try library.upsert(
            key,
            credential: .software(
                .init(
                    privateKey: String(contentsOfFile: remote.configuration.privateKeyPath, encoding: .utf8))))
        model = ActivationDeckModel(sessions: [SSHSessionModel(host: host), SSHSessionModel(host: host)])
        for session in model.sessions {
            session.sessionPersistence.attachment = remote.attachment(hostID: host.id)
            session.terminalState.setTerminalConfiguration(
                TerminalConfiguration { builder in
                    builder.withWindowPaddingX(0)
                    builder.withWindowPaddingY(0)
                })
        }
        hosting = NSHostingView(rootView: ActivationDeck(model: model))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 330))
        window = NSWindow(
            contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "tmux activation regression"
        window.contentView = content
        for view in [hosting, search] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            search.topAnchor.constraint(equalTo: content.topAnchor),
            search.heightAnchor.constraint(equalToConstant: 30),
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: search.bottomAnchor),
            hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
    }

    func show(_ index: Int) async throws {
        model.selected = index
        try await TmuxActivationFixture.wait {
            let session = self.model.sessions[index]
            return session.isTerminalActive && session.terminalState.surfaceSize != nil
        }
    }

    func waitForRuntime(_ session: SSHSessionModel) async throws {
        try await TmuxActivationFixture.wait {
            session.status == .connected && session.terminalContext.status == .multiplexer
        }
    }

    func focus(_ session: SSHSessionModel) throws {
        let view = try terminalView(session)
        #expect(window.makeFirstResponder(view))
    }

    func expectLayers(_ session: SSHSessionModel, label: String) async throws {
        try await TmuxActivationFixture.wait { session.isTerminalActive }
        let grid = try #require(session.terminalState.surfaceSize)
        let tty = try #require(session.terminalContext.clientIdentity?.split(separator: ":").first.map(String.init))
        try await remote.expectSize(columns: grid.columns, rows: grid.rows)
        let pty = try await remote.command("stty size -F \(RemoteTmuxCommands.quote(tty))")
        let client = try await remote.clientSize(tty)
        let inner = try await remote.windowSize()
        let view = try terminalView(session)
        let layers =
            "\(label): visible=\(hosting.bounds.size), native=\(view.bounds.size), "
            + "grid=\(grid.columns)x\(grid.rows), PTY=\(pty), client=\(client), window/pane=\(inner)"
        Attachment.record(Data(layers.utf8), named: "\(label).txt")
        #expect(view.bounds.size == hosting.bounds.size, Comment(rawValue: layers))
        #expect(pty == "\(grid.rows) \(grid.columns)", Comment(rawValue: layers))
        #expect(client == "\(grid.columns) \(grid.rows)", Comment(rawValue: layers))
    }

    private func terminalView(_ session: SSHSessionModel) throws -> TermindTerminalView {
        func find(in view: NSView) -> TermindTerminalView? {
            if let mount = view as? TerminalMountView, mount.owner === session.terminalViewOwner {
                return mount.subviews.first as? TermindTerminalView
            }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return try #require(find(in: hosting))
    }

    func close() {
        for session in model.sessions { session.disconnect() }
        window.contentView = nil
        window.close()
    }
}
