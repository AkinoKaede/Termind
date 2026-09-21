import Foundation
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct HostProtocolTests {
    @Test
    func hostDefaultsAndRequirementsAreProtocolSpecific() {
        var host = Host(name: "Server", host: "server.invalid")
        #expect(host.sshEnabled)
        #expect(host.sshPort == 22)
        #expect(host.sshCharset == .utf8)
        #expect(!host.telnetEnabled)
        #expect(host.telnetPort == 23)
        #expect(host.telnetCharset == .utf8)
        #expect(host.supportedTerminalProtocols == [.ssh])
        #expect(host.supports(.ssh))
        #expect(!host.supports(.telnet))

        host.sshEnabled = false
        host.telnetEnabled = true
        #expect(host.preferredTerminalProtocol == .telnet)
        #expect(host.supportedTerminalProtocols == [.telnet])
    }

    @Test
    func eligibilityFiltersEverySSHBackedUseCase() {
        let ssh = Host(name: "SSH", host: "ssh.invalid")
        let telnet = Host(
            name: "Telnet", host: "telnet.invalid",
            sshEnabled: false, telnetEnabled: true)
        let library = HostLibraryModel(hosts: [ssh, telnet])

        #expect(library.hosts(matching: "", for: .preferredTerminal).map(\.id) == [ssh.id, telnet.id])
        for useCase in [
            HostUseCase.sshTerminal, .sftp, .jumpHost, .metrics, .portForwarding,
            .snippetExecution, .keyExport,
        ] {
            #expect(library.hosts(matching: "", for: useCase).map(\.id) == [ssh.id])
            #expect(throws: HostProtocolUnavailableError.self) {
                try library.require(telnet, for: useCase)
            }
        }
        #expect(CredentialLibraryModel(library: library).searchHosts("").map(\.id) == [ssh.id])
        #expect(ForwardingLibraryModel(library: library).hosts.map(\.id) == [ssh.id])
        #expect(SnippetLibraryModel(library: library).searchHosts("").map(\.id) == [ssh.id])
    }

    @Test
    func savingRequiresAtLeastOneEnabledProtocol() {
        var host = Host(name: "Disabled", host: "disabled.invalid")
        host.sshEnabled = false
        let library = HostLibraryModel()
        #expect(!library.saveHost(host))

        host.telnetEnabled = true
        #expect(library.saveHost(host))
    }

    @Test
    func telnetNoneAllowsManualLoginWhileCustomRequiresPassword() {
        var host = Host(name: "Console", host: "console.invalid", sshEnabled: false, telnetEnabled: true)
        var draft = HostCustomIdentityDraft()
        #expect(draft.isTelnetValid(for: host))

        draft.selectCustomTelnet(on: &host)
        #expect(!draft.isTelnetValid(for: host))
        draft.telnetUsername = "operator"
        draft.telnetPassword = "secret"
        #expect(draft.isTelnetValid(for: host))
    }

    @Test
    func telnetCommandUsesOnlyTelnetProfile() throws {
        let identity = Identity(name: "Console", username: "operator", credentialRef: "password")
        var host = Host(
            name: "Console", host: "console.invalid",
            sshEnabled: false, telnetEnabled: true, telnetPort: 2323,
            telnetIdentityID: identity.id)
        host.sshPort = 2222
        let library = HostLibraryModel(hosts: [host], identities: [identity])
        #expect(library.telnetCommand(for: host) == "telnet -l operator console.invalid 2323")
    }

    @Test
    func version29ProjectionKeepsIndependentProfiles() {
        let sshIdentity = UUID()
        let telnetIdentity = UUID()
        let host = Host(
            name: "Dual", host: "dual.invalid", port: 2222, identityID: sshIdentity,
            charset: .gb18030, sshEnabled: true, telnetEnabled: true, telnetPort: 2323,
            telnetIdentityID: telnetIdentity, telnetCharset: .big5,
            telnetProxy: HostProxy(kind: .socks5, hostname: "proxy.invalid", port: 1080))

        let restored = PersistentHost(host).value
        #expect(restored.sshEnabled)
        #expect(restored.sshPort == 2222)
        #expect(restored.sshIdentityID == sshIdentity)
        #expect(restored.sshCharset == .gb18030)
        #expect(restored.telnetEnabled)
        #expect(restored.telnetPort == 2323)
        #expect(restored.telnetIdentityID == telnetIdentity)
        #expect(restored.telnetCharset == .big5)
        #expect(restored.telnetProxy?.hostname == "proxy.invalid")
    }
}
