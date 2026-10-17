import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized) @MainActor
struct HostShellIntegrationSessionTests {
    @Test(arguments: [false, true])
    func ordinaryStartupFallbackSubmitsOnceButNeverIntoManagedAttachments(managed: Bool) {
        let host = Host(name: "Server", host: "server.invalid", shellIntegrationMode: .enabled)
        let session = SSHSessionModel(hostID: host.id, title: host.name, initialCommand: "echo initial")
        var submitted = Data()
        session.inputSink = { submitted.append($0) }
        defer { session.disconnect() }
        session.connect(using: HostLibraryModel(hosts: [host]))
        session.status = .connected
        if managed {
            session.sessionPersistence.attachment = .init(
                backend: .tmux, session: .init(id: "$1", name: "build", identity: Data()),
                hostID: host.id, endpoint: "server.invalid:22", username: "user", ownershipToken: UUID())
        }
        session.receiveShellIntegrationEvent(.runtime(.init(status: .unknown)))
        session.receiveShellIntegrationEvent(.runtime(.init(status: .unavailable)))
        #expect(submitted.isEmpty)
        let fallback = SSHShellIntegrationEvent.ordinaryStartupUnavailable(
            ticket: .init(generation: UUID(), inputRevision: 0))
        session.receiveShellIntegrationEvent(fallback)
        session.receiveShellIntegrationEvent(fallback)
        session.receiveShellIntegrationEvent(.promptReady)
        #expect(String(decoding: submitted, as: UTF8.self) == (managed ? "" : "echo initial\r"))
        #expect(!session.shellIntegrationAvailable)
        #expect(!session.canGenerateFromCurrentDraft)
        #expect(session.workingDirectory == nil)
    }

    @Test func rejectedOrdinaryStartupDoesNotReplayAtALaterPrompt() {
        let host = Host(name: "Server", host: "server.invalid", shellIntegrationMode: .enabled)
        let session = SSHSessionModel(hostID: host.id, title: host.name, initialCommand: "echo initial")
        var submitted = Data()
        session.inputSink = { submitted.append($0) }
        defer { session.disconnect() }
        session.connect(using: HostLibraryModel(hosts: [host]))
        session.status = .connected
        session.receiveShellIntegrationEvent(.ordinaryStartupUnavailable(ticket: nil))
        session.receiveShellIntegrationEvent(.available(shell: "bash", systemInfo: nil, homeDirectory: "/home"))
        session.receiveShellIntegrationEvent(.promptReady)
        #expect(submitted.isEmpty)
    }

    @Test(arguments: ["shell", "tmux", "zellij", "zmx", "herdr"])
    func runningCommandsKeepTheDisplayedDirectoryUntilTheShellReportsAnother(backend: String) throws {
        let session = SSHSessionModel(hostID: UUID(), title: "Cwd")
        defer { session.disconnect() }
        session.status = .connected
        var context = TerminalShellContext(
            identity: .init(backend: backend, server: "s", session: "s", pane: "a", shellInstance: "i"),
            shell: "bash", directory: "/home/test/before", home: "/home/test", promptReady: true, sequence: 1,
            capabilities: [.directory, .commandLifecycle, .readDraft, .replaceDraft])
        let status: TerminalRuntimeUpdate.Status = backend == "shell" ? .ordinary : .multiplexer
        func receive() {
            session.receiveShellIntegrationEvent(
                .runtime(.init(status: status, active: context.identity, contexts: [context])))
        }
        receive()
        #expect(session.canGenerateFromCurrentDraft)
        let ticket = try #require(session.directoryContextTicket)
        context.sequence = 2
        context.promptReady = false
        context.capabilities = [.commandLifecycle]
        receive()
        #expect(session.workingDirectory == "/home/test/before")
        #expect(session.displayedWorkingDirectory == "~/before")
        #expect(!session.canGenerateFromCurrentDraft)
        #expect(!session.isDirectoryContextCurrent(ticket))
        context.sequence = 3
        context.directory = "/home/test/after"
        receive()
        #expect(session.workingDirectory == "/home/test/after")
        #expect(session.displayedWorkingDirectory == "~/after")
        #expect(!session.canGenerateFromCurrentDraft)
        session.receiveShellIntegrationEvent(.runtime(.init(status: .unavailable)))
        #expect(session.workingDirectory == nil)
    }

    @Test(arguments: [false, true])
    func paneHistoryInvalidationDoesNotDependOnSessionPersistence(managed: Bool) async {
        let session = SSHSessionModel(hostID: UUID(), title: "History")
        defer { session.disconnect() }
        if managed {
            session.sessionPersistence.attachment = .init(
                backend: .tmux, session: .init(id: "test", name: "Test", identity: Data()),
                hostID: session.hostID, endpoint: "test:22", username: "user", ownershipToken: UUID())
        }
        let context = TerminalShellContext(
            identity: .init(backend: "test", server: "s", session: "s", pane: "a", shellInstance: "i"),
            shell: "bash", directory: "/", home: "/home/test", promptReady: true, sequence: 1,
            capabilities: [.commandLifecycle], historyPath: "/home/test/history")
        session.receiveShellIntegrationEvent(
            .runtime(.init(status: .multiplexer, active: context.identity, contexts: [context])))
        session.commandHistory.load(using: HistoryLoader(), source: context.historySource)
        for _ in 0..<1000 {
            if session.commandHistory.hasLoaded { break }
            await Task.yield()
        }
        #expect(session.commandHistory.entries().map(\.command) == ["imported"])
        session.receiveShellIntegrationEvent(
            .runtime(.init(status: .multiplexer, active: context.identity, contexts: [context])))
        #expect(session.commandHistory.hasLoaded)
        session.receiveShellIntegrationEvent(.runtime(.init(status: .unknown)))
        #expect(session.commandHistory.entries().isEmpty)
        #expect(!session.commandHistory.hasLoaded)
    }

    private struct HistoryLoader: ShellHistoryLoading {
        func load(source: ShellHistorySource?) async throws -> [ShellHistoryRecord] { [.init(command: "imported")] }
    }

    @Test func runtimeContextGatesEnhancementsWithoutPersistence() throws {
        let host = Host(name: "Server", host: "server.invalid", shellIntegrationMode: .enabled)
        let session = SSHSessionModel(hostID: host.id, title: host.name)
        session.connect(using: HostLibraryModel(hosts: [host]))
        defer { session.disconnect() }
        session.status = .connected
        let context = TerminalShellContext(
            identity: .init(backend: "test-multiplexer", server: "s", session: "s", pane: "a", shellInstance: "i"),
            shell: "bash", directory: "/pane-a", home: "/home/test", promptReady: true, sequence: 1,
            capabilities: [.directory, .commandLifecycle, .readDraft, .replaceDraft])
        session.receiveShellIntegrationEvent(
            .runtime(
                .init(
                    status: .multiplexer, active: context.identity, contexts: [context])))
        #expect(!host.sessionPersistence.enabled)
        #expect(session.canGenerateFromCurrentDraft)
        #expect(session.workingDirectory == "/pane-a")
        let ticket = try #require(session.directoryContextTicket)
        session.receiveShellIntegrationEvent(.runtime(.init(status: .unknown)))
        #expect(session.workingDirectory == nil)
        #expect(!session.canGenerateFromCurrentDraft)
        #expect(!session.isDirectoryContextCurrent(ticket))
        session.receiveShellIntegrationEvent(.available(shell: "bash", systemInfo: nil, homeDirectory: "/stale"))
        session.receiveShellIntegrationEvent(.promptReady)
        #expect(!session.canGenerateFromCurrentDraft)
        #expect(session.workingDirectory == nil)
    }

    @Test(arguments: HostShellIntegrationMode.allCases, [false, true])
    func connectionRetainsItsPreferenceUntilTheNextAttempt(mode: HostShellIntegrationMode, global: Bool) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SettingsKey.shellIntegration)
        defer { defaults.set(previous, forKey: SettingsKey.shellIntegration) }
        defaults.set(global, forKey: SettingsKey.shellIntegration)
        var host = Host(name: "Server", host: "server.invalid", shellIntegrationMode: mode)
        let library = HostLibraryModel(hosts: [host])
        let session = SSHSessionModel(hostID: host.id, title: host.name)
        let history = session.commandHistory
        defer { session.disconnect() }
        // The missing identity holds connection setup at authentication without opening a socket.
        session.connect(using: library)
        let expected = mode.isEnabled(globalSetting: global)
        #expect(session.isShellIntegrationEnabled == expected)
        session.status = .connected
        let info = RemoteSystemInfo(kernelName: "Linux", kernelRelease: "6.8", architecture: "x86_64")
        session.receiveShellIntegrationEvent(.available(shell: "bash", systemInfo: info, homeDirectory: "/home/test"))
        session.receiveShellIntegrationEvent(.promptReady)
        let pane = Pane(.sshSession(session))
        #expect(pane.remoteSystemInfo == (expected ? info : nil))
        #expect(session.canGenerateFromCurrentDraft == expected)

        defaults.set(!global, forKey: SettingsKey.shellIntegration)
        host.shellIntegrationMode = expected ? .disabled : .enabled
        library.upsert(host)
        #expect(session.isShellIntegrationEnabled == expected)
        #expect(pane.remoteSystemInfo == (expected ? info : nil))
        #expect(session.canGenerateFromCurrentDraft == expected)
        session.receiveShellIntegrationEvent(.commandStarted("pwd"))
        session.receiveShellIntegrationEvent(.commandFinished(0, duration: 0.1))
        #expect(history.entries().count == (expected ? 1 : 0))
        library.replacePersistedSnapshot(VaultSnapshot(hosts: [host]))
        #expect(session.isShellIntegrationEnabled == expected)

        session.disconnect()
        session.connect(using: library)
        #expect(session.isShellIntegrationEnabled == !expected)
        #expect(session.remoteSystemInfo == nil)

        host.shellIntegrationMode = .followGlobalSettings
        library.replacePersistedSnapshot(VaultSnapshot(hosts: [host]))
        session.disconnect()
        session.connect(using: library)
        #expect(session.isShellIntegrationEnabled == !global)
    }

    @Test func transientHostOverrideIsUsedAtConnectionStart() {
        let host = Host(name: "Quick Connect", host: "quick.invalid", shellIntegrationMode: .disabled)
        let session = SSHSessionModel(host: host)
        defer { session.disconnect() }
        session.connect(using: HostLibraryModel())
        #expect(!session.isShellIntegrationEnabled)
    }

    @Test func startupSnippetUsesExplicitLaunchOnceAndResolvesLatestBodyOnReconnect() {
        var startup = Snippet(title: "Startup", body: "echo first")
        let host = Host(
            name: "Server", host: "server.invalid", startupSnippetID: startup.id
        )
        let library = HostLibraryModel(hosts: [host], snippets: [startup])
        let session = SSHSessionModel(
            hostID: host.id, title: host.name, initialCommand: "echo explicit"
        )
        var submitted = Data()
        session.inputSink = { submitted.append($0) }
        defer { session.disconnect() }

        session.connect(using: library)
        session.status = .connected
        session.receiveShellIntegrationEvent(
            .available(shell: "bash", systemInfo: nil, homeDirectory: "/home/test")
        )
        #expect(String(decoding: submitted, as: UTF8.self) == "echo explicit\r")

        session.disconnect()
        startup.body = "echo latest"
        library.upsert(startup)
        session.connect(using: library)
        session.status = .connected
        session.receiveShellIntegrationEvent(
            .available(shell: "bash", systemInfo: nil, homeDirectory: "/home/test")
        )
        #expect(
            String(decoding: submitted, as: UTF8.self)
                == "echo explicit\recho latest\r"
        )
    }
}
