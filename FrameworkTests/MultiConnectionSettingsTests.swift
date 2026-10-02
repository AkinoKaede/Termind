import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import Testing

@Suite @MainActor
struct MultiConnectionSettingsTests {
    @Test(arguments: SFTPConcurrencyStrategy.allCases)
    func freeDisplayAndOtherEditsPreserveTheSavedStrategy(_ strategy: SFTPConcurrencyStrategy) {
        let persistence = SettingsStore(.init(strategy: strategy))
        let settings = SFTPSettingsModel(persistence: persistence)
        let pro = ProAccessController.testing(status: .free(trialAvailable: true))
        let access = MultiConnectionSettingsAccess(isAllowed: false) { pro.require(.sftpMultiConnection) }
        let selection = access.strategy(for: settings)
        #expect(selection.wrappedValue == .channelsOnly)
        #expect(persistence.saves == 0)
        selection.wrappedValue = .channelsOnly
        #expect(persistence.saves == 0)
        selection.wrappedValue = .smart
        selection.wrappedValue = .connectionsPreferred
        #expect(pro.isPaywallPresented)
        #expect(persistence.saves == 0)
        #expect(settings.set(12, for: \.globalLimit))
        #expect(persistence.value.strategy == strategy)
        #expect(persistence.saves == 1)
        let upgraded = MultiConnectionSettingsAccess(isAllowed: true, requestAccess: {})
        #expect(upgraded.strategy(for: settings).wrappedValue == strategy)
    }

    @Test func freeHostEditorSavesOtherFieldsWithoutReplacingItsConnectionCount() {
        var host = Host(name: "Before", host: "example.invalid", portForwardingMaxConnections: 8)
        var prompts = 0
        let saved = Binding(get: { host.portForwardingMaxConnections }, set: { host.portForwardingMaxConnections = $0 })
        let free = MultiConnectionSettingsAccess(isAllowed: false) { prompts += 1 }.forwardingConnections(saved)
        #expect(free.wrappedValue == 1)
        free.wrappedValue = 1
        free.wrappedValue = 2
        host.name = "After"
        #expect(host.portForwardingMaxConnections == 8)
        #expect(prompts == 1)
        let paid = MultiConnectionSettingsAccess(isAllowed: true, requestAccess: {}).forwardingConnections(saved)
        #expect(paid.wrappedValue == 8)
        paid.wrappedValue = 4
        #expect(host.portForwardingMaxConnections == 4)
    }

    @Test(arguments: SFTPConcurrencyStrategy.allCases)
    func runtimeProjectionPreservesSavedPreferencesWithoutOpeningPaywall(_ strategy: SFTPConcurrencyStrategy) {
        let saved = SFTPPreferences(globalLimit: 80, perHostLimit: 40, strategy: strategy)
        let free = ProAccessController.testing(status: .verificationFailed)
        let effective = free.effectiveSFTPPreferences(saved)
        #expect(effective == SFTPPreferences(globalLimit: 80, perHostLimit: 40, strategy: .channelsOnly))
        #expect(free.effectiveForwardingConnections(8) == 1)
        #expect(!free.isPaywallPresented)
        let paid = ProAccessController.testing(status: .purchased(.familyShared))
        #expect(paid.effectiveSFTPPreferences(saved) == saved)
        #expect(paid.effectiveForwardingConnections(8) == 8)
        #expect(!paid.isPaywallPresented)
    }
}

@MainActor
private final class SettingsStore: SFTPPreferencesPersisting {
    var value: SFTPPreferences
    var saves = 0
    init(_ value: SFTPPreferences) { self.value = value }
    func loadSFTP() throws -> SFTPPreferences { value }
    func saveSFTP(_ value: SFTPPreferences) throws {
        self.value = value
        saves += 1
    }
}
