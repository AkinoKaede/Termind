import TermindDomain
import Testing

@testable import TermindIOS
@testable import TermindInfrastructure

@Suite @MainActor
struct MobileMultiConnectionAccessTests {
    @Test(arguments: SFTPConcurrencyStrategy.allCases)
    func entitlementChangesPreserveSavedSettingsWithoutAnyScene(_ strategy: SFTPConcurrencyStrategy) async throws {
        let service = MobileConnectionPurchaseService()
        let pro = ProAccessController(purchaseService: service, observeUpdates: false)
        var dependencies = MobileAppDependencies.testing()
        dependencies.proAccess = pro
        let app = try MobileAppModel(dependencies: dependencies)
        app.sftpSettings.setStrategy(strategy)
        #expect(app.transfers.strategy == .channelsOnly)
        service.status = .purchased(.purchased)
        await pro.refresh()
        #expect(app.transfers.strategy == strategy)
        service.status = .free(trialAvailable: false)
        await pro.refresh()
        #expect(app.transfers.strategy == .channelsOnly)
        #expect(app.sftpSettings.preferences.strategy == strategy)
        app.sftpSettings.set(60, for: \.globalLimit)
        #expect(app.transfers.globalLimit == 60)
        #expect(app.transfers.strategy == .channelsOnly)
        #expect(!pro.isPaywallPresented)
    }
}

@MainActor
private final class MobileConnectionPurchaseService: ProPurchaseService {
    let updates = AsyncStream<EntitlementStatus> { $0.finish() }
    var status = EntitlementStatus.free(trialAvailable: false)
    func currentStatus() async throws -> EntitlementStatus { status }
}
