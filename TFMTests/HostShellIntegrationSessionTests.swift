import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized) @MainActor
struct HostShellIntegrationSessionTests {
    @Test(arguments: HostShellIntegrationMode.allCases, [false, true])
    func connectionRetainsItsPreferenceUntilTheNextAttempt(mode: HostShellIntegrationMode, global: Bool) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SettingsKey.shellIntegration)
        defer { defaults.set(previous, forKey: SettingsKey.shellIntegration) }
        defaults.set(global, forKey: SettingsKey.shellIntegration)
        var host = Host(name: "Server", host: "server.invalid", shellIntegrationMode: mode)
        let library = HostLibraryModel(hosts: [host])
        let session = SSHSessionModel(hostID: host.id, title: host.name)
        let history = CommandHistoryModel()
        session.commandHistoryStore = history
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
        #expect(history.entries(for: host.id).count == (expected ? 1 : 0))
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
