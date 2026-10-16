import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct WakeOnLANAccessTests {
    @Test(arguments: ["", "02:11:22:33:44:55"])
    func lockedManualWakePresentsPaywallWithoutConfigurationOrPacket(macAddress: String) {
        var hosts = (0..<4).map {
            Host(name: "Host \($0)", host: "host.invalid", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        hosts[3].wakeOnLAN.macAddress = macAddress
        let pro = ProAccessController.testing(status: .free)
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts), proAccess: pro)
        defer { app.shutdownForTermination() }
        app.hostLibrary.wakeOnLAN = WakeOnLANController(sender: UnexpectedWakeSender())
        var configured = false
        #expect(app.requestWake(hosts[3]) { configured = true } == nil)
        #expect(pro.isPaywallPresented)
        #expect(!configured)
    }

    @Test(arguments: [LocalDiscoveryProtocol.ssh, .telnet])
    func discoveryUsesTheSelectedProtocolWithoutRequestingPro(_ connectionProtocol: LocalDiscoveryProtocol) {
        let pro = ProAccessController.testing(status: .free)
        let app = AppModel(hosts: HostLibraryModel(), proAccess: pro)
        defer { app.shutdownForTermination() }
        let model = app.localDiscoveryModel(protocol: connectionProtocol)
        #expect(model.connectionProtocol == connectionProtocol)
        #expect(model.phase == .idle)
        #expect(!pro.isPaywallPresented)
    }

    @Test func freeManualWakeOpensConfigurationWithoutPaywall() {
        let pro = ProAccessController.testing(status: .free)
        let app = AppModel(hosts: HostLibraryModel(), proAccess: pro)
        var configured = false
        #expect(app.requestWake(Host(name: "Host", host: "server.invalid")) { configured = true } == nil)
        #expect(!pro.isPaywallPresented)
        #expect(configured)
    }

    @Test func proWakeWithoutMACOpensConfigurationRatherThanSending() {
        let app = AppModel(hosts: HostLibraryModel())
        var configured = false
        #expect(app.requestWake(Host(name: "Host", host: "server.invalid")) { configured = true } == nil)
        #expect(configured)
        #expect(!app.proAccess.isPaywallPresented)
    }

    @Test func autoWakeIsFreeAndPreservesPreferences() {
        let pro = ProAccessController.testing(status: .free)
        var preferences = WakeOnLANPreferences(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        let binding = Binding(get: { preferences }, set: { preferences = $0 })
        var invalid = false
        let access = WakeOnLANSettingsAccess(
            invalidAddress: { invalid = true })
        let automatic = access.automatic(binding)
        #expect(automatic.wrappedValue)
        #expect(preferences.automaticallyWake)
        #expect(!pro.isPaywallPresented)
        automatic.wrappedValue = false
        #expect(!pro.isPaywallPresented)
        #expect(!preferences.automaticallyWake)
        automatic.wrappedValue = true
        #expect(!pro.isPaywallPresented)
        #expect(preferences.automaticallyWake)
        #expect(preferences.macAddress == "02:11:22:33:44:55")
        #expect(!invalid)
    }

    @Test func enablingAutoRequiresValidMACWithoutChangingTheDraft() {
        var preferences = WakeOnLANPreferences()
        var invalid = false
        let access = WakeOnLANSettingsAccess(invalidAddress: { invalid = true })
        access.automatic(Binding(get: { preferences }, set: { preferences = $0 })).wrappedValue = true
        #expect(invalid)
        #expect(!preferences.automaticallyWake)
    }
}

private nonisolated struct UnexpectedWakeSender: WakeOnLANSending {
    func send(to address: MACAddress) throws { Issue.record("A locked host must not send a Wake packet") }
}
