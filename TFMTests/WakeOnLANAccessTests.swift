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
    @Test(arguments: [EntitlementStatus.purchased(.purchased), .free, .verificationFailed])
    func pendingManualWakeResumesOnceWithTypedAccessPresentation(status: EntitlementStatus) async throws {
        var hosts = (0..<4).map {
            Host(name: "Host \($0)", host: "host.invalid", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        hosts[3].wakeOnLAN.macAddress = "02:11:22:33:44:55"
        let pro = ProAccessController.testing(status: .free)
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts), proAccess: pro)
        defer { app.shutdownForTermination() }
        let sender = RecordedDesktopWakeSender()
        app.hostLibrary.wakeOnLAN = WakeOnLANController(sender: sender)
        app.hostLibrary.hostAccess.entitlement = .loading
        var continuation: CheckedContinuation<Void, Never>?
        app.hostLibrary.resolveInitialHostEntitlement = {
            await withCheckedContinuation { continuation = $0 }
            app.hostLibrary.hostAccess.entitlement = status
        }
        defer { app.hostLibrary.resolveInitialHostEntitlement = nil }
        var configured = false
        let target = hosts[3]
        let operation = Task { await app.requestWake(target) { configured = true } }
        for _ in 0..<200 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(continuation != nil)
        #expect(sender.count == 0)
        #expect(!pro.isPaywallPresented)
        continuation?.resume()
        let notice = await operation.value
        #expect(!configured)
        #expect(pro.isPaywallPresented == (status == .free))
        #expect(sender.count == (status.hasProAccess ? 1 : 0))
        if status.hasProAccess {
            #expect(notice == String(localized: AppStrings.LocalNetwork.sent))
        } else if status == .verificationFailed {
            #expect(notice == HostAccessError.entitlementVerificationFailed.localizedDescription)
        } else {
            #expect(notice == nil)
        }
    }

    @Test(arguments: ["", "02:11:22:33:44:55"])
    func lockedManualWakePresentsPaywallWithoutConfigurationOrPacket(macAddress: String) async {
        var hosts = (0..<4).map {
            Host(name: "Host \($0)", host: "host.invalid", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        hosts[3].wakeOnLAN.macAddress = macAddress
        let pro = ProAccessController.testing(status: .free)
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts), proAccess: pro)
        defer { app.shutdownForTermination() }
        app.hostLibrary.wakeOnLAN = WakeOnLANController(sender: UnexpectedWakeSender())
        var configured = false
        let notice = await app.requestWake(hosts[3]) { configured = true }
        #expect(notice == nil)
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

    @Test func freeManualWakeOpensConfigurationWithoutPaywall() async {
        let pro = ProAccessController.testing(status: .free)
        let app = AppModel(hosts: HostLibraryModel(), proAccess: pro)
        var configured = false
        let notice = await app.requestWake(Host(name: "Host", host: "server.invalid")) { configured = true }
        #expect(notice == nil)
        #expect(!pro.isPaywallPresented)
        #expect(configured)
    }

    @Test func proWakeWithoutMACOpensConfigurationRatherThanSending() async {
        let app = AppModel(hosts: HostLibraryModel())
        var configured = false
        let notice = await app.requestWake(Host(name: "Host", host: "server.invalid")) { configured = true }
        #expect(notice == nil)
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

    @Test func editingAnEnabledWakeAddressPreservesTheToggleUntilCorrectedOrDisabled() {
        var preferences = WakeOnLANPreferences(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        let binding = Binding(get: { preferences }, set: { preferences = $0 })
        let automatic = WakeOnLANSettingsAccess(invalidAddress: {}).automatic(binding)
        for address in ["02:11:22:33:44:GG", ""] {
            binding.macAddress.wrappedValue = address
            #expect(automatic.wrappedValue)
            #expect(!preferences.isValid)
        }
        binding.macAddress.wrappedValue = "02-ab-cd-12-34-56"
        #expect(preferences.isValid)
        binding.macAddress.wrappedValue = ""
        automatic.wrappedValue = false
        #expect(preferences.isValid)
    }

    @Test func invalidWakeSaveUsesTheSharedMACValidationMessage() {
        var host = Host(name: "Host", host: "server.invalid")
        host.wakeOnLAN.macAddress = "invalid"
        let library = HostLibraryModel()
        let message = String(localized: AppStrings.LocalNetwork.invalidMACAddress)
        #expect(HostAccessError.presentationDescription(of: WakeOnLANError.invalidAddress) == message)
        #expect(!library.saveHost(host))
        #expect(library.storageError == message)
    }
}

private nonisolated struct UnexpectedWakeSender: WakeOnLANSending {
    func send(to address: MACAddress) throws { Issue.record("A locked host must not send a Wake packet") }
}

private nonisolated final class RecordedDesktopWakeSender: WakeOnLANSending, @unchecked Sendable {
    private let lock = NSLock()
    private var packets = 0
    var count: Int { lock.withLock { packets } }
    func send(to address: MACAddress) { lock.withLock { packets += 1 } }
}
