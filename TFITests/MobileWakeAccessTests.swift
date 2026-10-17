import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileWakeAccessTests {
    @Test(arguments: [EntitlementStatus.purchased(.purchased), .free, .verificationFailed])
    func pendingManualWakeResumesOnceWithTypedAccessPresentation(status: EntitlementStatus) async throws {
        var dependencies = MobileAppDependencies.testing()
        dependencies.proAccess = .testing(status: .free)
        let app = try MobileAppModel(dependencies: dependencies)
        defer {
            app.metrics.core.shutdown()
            app.outbox.stop()
        }
        app.library.hostAccess.entitlement = .unrestrictedForTesting
        for index in 0..<4 {
            var host = TermindDomain.Host(name: "Host \(index)", host: "host.invalid")
            host.wakeOnLAN.macAddress = "02:11:22:33:44:55"
            app.library.upsert(host)
        }
        let target = try #require(app.library.hosts.last)
        let sender = RecordedMobileWakeSender()
        app.library.wakeOnLAN = WakeOnLANController(sender: sender)
        app.library.hostAccess.entitlement = .loading
        var continuation: CheckedContinuation<Void, Never>?
        app.library.resolveInitialHostEntitlement = {
            await withCheckedContinuation { continuation = $0 }
            app.library.hostAccess.entitlement = status
        }
        defer { app.library.resolveInitialHostEntitlement = nil }
        var configured = false
        let operation = Task { await app.requestWake(target) { configured = true } }
        for _ in 0..<200 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(continuation != nil)
        #expect(sender.count == 0)
        #expect(!app.pro.isPaywallPresented)
        continuation?.resume()
        let notice = await operation.value
        #expect(!configured)
        #expect(app.pro.isPaywallPresented == (status == .free))
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
    func lockedManualWakePresentsPaywallWithoutConfigurationOrPacket(macAddress: String) async throws {
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
        let notice = await app.requestWake(locked) { configured = true }
        #expect(notice == nil)
        #expect(app.pro.isPaywallPresented)
        #expect(!configured)
    }
}

private nonisolated struct UnexpectedMobileWakeSender: WakeOnLANSending {
    func send(to address: MACAddress) throws { Issue.record("A locked host must not send a Wake packet") }
}

private nonisolated final class RecordedMobileWakeSender: WakeOnLANSending, @unchecked Sendable {
    private let lock = NSLock()
    private var packets = 0
    var count: Int { lock.withLock { packets } }
    func send(to address: MACAddress) { lock.withLock { packets += 1 } }
}
