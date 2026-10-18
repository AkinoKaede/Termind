import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized) @MainActor
struct HostShellIntegrationSessionTests {
    @Test func resizeThrottleFollowsLegacyLifecycleRatherThanCommandCompletion() {
        let session = SSHSessionModel(hostID: UUID(), title: "Resize lifecycle")
        defer { session.disconnect() }
        let owner = session.terminalViewOwner
        #expect(owner.resizeThrottleMilliseconds == 35)
        session.receiveShellIntegrationEvent(.available(shell: "bash", systemInfo: nil, homeDirectory: nil))
        #expect(owner.resizeThrottleMilliseconds == 35)
        session.status = .connected
        #expect(owner.resizeThrottleMilliseconds == 128)
        session.receiveShellIntegrationEvent(.promptReady)
        #expect(owner.resizeThrottleMilliseconds == 0)
        session.receiveShellIntegrationEvent(.commandStarted("top"))
        #expect(owner.resizeThrottleMilliseconds == 128)
        session.receiveShellIntegrationEvent(.commandFinished(0, duration: 1))
        #expect(owner.resizeThrottleMilliseconds == 128)
        session.receiveShellIntegrationEvent(.promptReady)
        #expect(owner.resizeThrottleMilliseconds == 0)
        session.receiveShellIntegrationEvent(.available(shell: "bash", systemInfo: nil, homeDirectory: nil))
        #expect(owner.resizeThrottleMilliseconds == 128)
        session.status = .reconnecting
        #expect(owner.resizeThrottleMilliseconds == 35)
        session.receiveShellIntegrationEvent(.promptReady)
        #expect(owner.resizeThrottleMilliseconds == 35)
        session.status = .connected
        #expect(owner.resizeThrottleMilliseconds == 0)
        session.status = .failed("Disconnected")
        #expect(owner.resizeThrottleMilliseconds == 35)
    }

    @Test(arguments: [TerminalRuntimeUpdate.Status.ordinary, .multiplexer])
    func runtimeResizeThrottleRequiresLifecycleAndInteractivePrompt(status: TerminalRuntimeUpdate.Status) {
        let session = SSHSessionModel(hostID: UUID(), title: "Runtime resize")
        defer { session.disconnect() }
        session.status = .connected
        let owner = session.terminalViewOwner
        var context = TerminalShellContext(
            identity: .init(backend: "tmux", server: "s", session: "s", pane: "a", shellInstance: "i"),
            shell: "bash", directory: nil, home: nil, promptReady: false, sequence: 1,
            capabilities: [.commandLifecycle])
        func receive() {
            session.receiveShellIntegrationEvent(
                .runtime(.init(status: status, active: context.identity, contexts: [context])))
            context.sequence += 1
        }
        receive()
        #expect(owner.resizeThrottleMilliseconds == 128)
        // A prompt snapshot without readDraft also represents tmux copy/prefix
        // mode or a foreground process that is no longer the shell.
        context.promptReady = true
        receive()
        #expect(owner.resizeThrottleMilliseconds == 128)
        context.capabilities.insert(.readDraft)
        receive()
        #expect(owner.resizeThrottleMilliseconds == 0)
        #expect(!session.canGenerateFromCurrentDraft)  // Resize does not require replaceDraft.
        context.capabilities.remove(.readDraft)
        receive()
        #expect(owner.resizeThrottleMilliseconds == 128)
        session.receiveShellIntegrationEvent(.promptReady)
        #expect(owner.resizeThrottleMilliseconds == 128)
        context.capabilities = [.readDraft]
        receive()
        #expect(owner.resizeThrottleMilliseconds == 35)
        context.capabilities.insert(.commandLifecycle)
        receive()
        #expect(owner.resizeThrottleMilliseconds == 0)
        context.promptReady = false
        receive()
        #expect(owner.resizeThrottleMilliseconds == 128)
        for unavailable in [TerminalRuntimeUpdate.Status.unknown, .unavailable] {
            session.receiveShellIntegrationEvent(.runtime(.init(status: unavailable)))
            #expect(owner.resizeThrottleMilliseconds == 35)
            session.receiveShellIntegrationEvent(.available(shell: "bash", systemInfo: nil, homeDirectory: nil))
            session.receiveShellIntegrationEvent(.promptReady)
            #expect(owner.resizeThrottleMilliseconds == 35)
        }
    }

    @Test func reconnectResetsResizeThrottleUntilFreshShellStateArrives() {
        let host = Host(name: "Server", host: "server.invalid", shellIntegrationMode: .enabled)
        let library = HostLibraryModel(hosts: [host])
        let session = SSHSessionModel(hostID: host.id, title: host.name)
        defer { session.disconnect() }
        // Missing authentication keeps setup local; no socket is opened.
        session.connect(using: library)
        session.status = .connected
        let context = TerminalShellContext(
            identity: .init(backend: "shell", server: "s", session: "s", pane: "a", shellInstance: "i"),
            shell: "bash", directory: nil, home: nil, promptReady: true, sequence: 1,
            capabilities: [.commandLifecycle, .readDraft])
        session.receiveShellIntegrationEvent(
            .runtime(.init(status: .ordinary, active: context.identity, contexts: [context])))
        #expect(session.terminalViewOwner.resizeThrottleMilliseconds == 0)
        session.disconnect()
        #expect(session.terminalViewOwner.resizeThrottleMilliseconds == 35)
        session.connect(using: library)
        session.status = .connected
        #expect(session.terminalViewOwner.resizeThrottleMilliseconds == 35)
        session.receiveShellIntegrationEvent(.runtime(.init(status: .unknown)))
        #expect(session.terminalViewOwner.resizeThrottleMilliseconds == 35)
        session.receiveShellIntegrationEvent(
            .runtime(.init(status: .ordinary, active: context.identity, contexts: [context])))
        #expect(session.terminalViewOwner.resizeThrottleMilliseconds == 0)
    }

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
        #expect(session.terminalViewOwner.resizeThrottleMilliseconds == (expected ? 0 : 35))

        defaults.set(!global, forKey: SettingsKey.shellIntegration)
        host.shellIntegrationMode = expected ? .disabled : .enabled
        library.upsert(host)
        #expect(session.isShellIntegrationEnabled == expected)
        #expect(pane.remoteSystemInfo == (expected ? info : nil))
        #expect(session.canGenerateFromCurrentDraft == expected)
        #expect(session.terminalViewOwner.resizeThrottleMilliseconds == (expected ? 0 : 35))
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
