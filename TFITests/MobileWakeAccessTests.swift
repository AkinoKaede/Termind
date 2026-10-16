import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileWakeAccessTests {
    @Test(arguments: ["", "02:11:22:33:44:55"])
    func lockedManualWakePresentsPaywallWithoutConfigurationOrPacket(macAddress: String) throws {
        var dependencies = MobileAppDependencies.testing()
        dependencies.proAccess = .testing(status: .free)
        let app = try MobileAppModel(dependencies: dependencies)
        defer {
            app.metrics.core.shutdown()
            app.outbox.stop()
        }
        app.library.hostAccess.entitlement = .unrestrictedForTesting
        for index in 0..<4 {
            app.library.upsert(TermindDomain.Host(name: "Host \(index)", host: "host.invalid"))
        }
        var locked = try #require(app.library.hosts.last)
        locked.wakeOnLAN.macAddress = macAddress
        app.library.upsert(locked)
        app.library.hostAccess.entitlement = .free
        app.library.wakeOnLAN = WakeOnLANController(sender: UnexpectedMobileWakeSender())
        #expect(app.library.isLocked(locked))
        var configured = false
        #expect(app.requestWake(locked) { configured = true } == nil)
        #expect(app.pro.isPaywallPresented)
        #expect(!configured)
    }
}

private nonisolated struct UnexpectedMobileWakeSender: WakeOnLANSending {
    func send(to address: MACAddress) throws { Issue.record("A locked host must not send a Wake packet") }
}
