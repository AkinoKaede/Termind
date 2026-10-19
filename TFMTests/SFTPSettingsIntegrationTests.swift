import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind
@testable import TermindInfrastructure

@Suite(.serialized) @MainActor
struct SFTPSettingsIntegrationTests {
    @Test(arguments: SFTPConcurrencyStrategy.allCases)
    func purchaseRestoresSavedStrategyWithoutOpeningSettings(_ strategy: SFTPConcurrencyStrategy) async {
        let service = ConnectionPurchaseService()
        let pro = ProAccessController(purchaseService: service, observeUpdates: false)
        let settings = SFTPSettingsModel()
        settings.setStrategy(strategy)
        let app = AppModel(hosts: HostLibraryModel(), sftpSettings: settings, proAccess: pro)
        defer { app.shutdownForTermination() }
        #expect(app.sftpTransfers.strategy == .channelsOnly)
        settings.set(60, for: \.globalLimit)
        service.status = .purchased(.purchased)
        await pro.refresh()
        #expect(app.sftpTransfers.strategy == strategy)
        #expect(app.sftpTransfers.globalLimit == 60)
        #expect(settings.preferences.strategy == strategy)
        #expect(!pro.isPaywallPresented)
    }
    @Test(arguments: SFTPConcurrencyStrategy.allCases)
    func losingAccessChangesRuntimeWithoutRewritingPreferencesOrOpeningPaywall(_ strategy: SFTPConcurrencyStrategy)
        async
    {
        let settings = SFTPSettingsModel()
        settings.setStrategy(strategy)
        let pro = ProAccessController.testing(status: .purchased(.purchased))
        let app = AppModel(hosts: HostLibraryModel(), sftpSettings: settings, proAccess: pro)
        defer { app.shutdownForTermination() }
        #expect(app.sftpTransfers.strategy == strategy)
        await pro.refresh()
        #expect(app.sftpTransfers.strategy == .channelsOnly)
        #expect(settings.preferences.strategy == strategy)
        #expect(!pro.isPaywallPresented)
        settings.set(50, for: \.globalLimit)
        #expect(app.sftpTransfers.strategy == .channelsOnly)
        #expect(app.sftpTransfers.globalLimit == 50)
        #expect(settings.preferences.strategy == strategy)
    }

    @Test func freeStartupAndSyncedPreferencesUseOnlyTheEffectiveStrategy() {
        let settings = SFTPSettingsModel()
        let pro = ProAccessController.testing(status: .free)
        let app = AppModel(hosts: HostLibraryModel(), sftpSettings: settings, proAccess: pro)
        defer { app.shutdownForTermination() }
        #expect(settings.preferences.strategy == .smart)
        #expect(app.sftpTransfers.strategy == .channelsOnly)
        settings.applyRemoteSnapshot(.init(strategy: .connectionsPreferred))
        #expect(settings.preferences.strategy == .connectionsPreferred)
        #expect(app.sftpTransfers.strategy == .channelsOnly)
        #expect(!pro.isPaywallPresented)
    }

    @Test func localAndRemoteChangesReachTheQueueWithoutOpeningSettings() {
        let settings = SFTPSettingsModel()
        let app = AppModel(hosts: HostLibraryModel(), sftpSettings: settings)
        defer { app.shutdownForTermination() }
        #expect(app.sftpTransfers.globalLimit == 30)
        #expect(app.sftpTransfers.perHostLimit == 10)
        #expect(app.sftpTransfers.strategy == .smart)
        #expect(settings.set(100, for: \.globalLimit))
        #expect(settings.set(50, for: \.perHostLimit))
        #expect(settings.setStrategy(.connectionsPreferred))
        #expect(app.sftpTransfers.globalLimit == 100)
        #expect(app.sftpTransfers.perHostLimit == 50)
        #expect(app.sftpTransfers.strategy == .connectionsPreferred)
        settings.applyRemoteSnapshot(SFTPPreferences(globalLimit: 3, perHostLimit: 2, strategy: .channelsOnly))
        #expect(app.sftpTransfers.globalLimit == 3)
        #expect(app.sftpTransfers.perHostLimit == 2)
        #expect(app.sftpTransfers.strategy == .channelsOnly)
    }

}

@MainActor
private final class ConnectionPurchaseService: ProPurchaseService {
    let updates = AsyncStream<EntitlementStatus> { $0.finish() }
    var status = EntitlementStatus.free
    func currentStatus() async throws -> EntitlementStatus { status }
}
