// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@Suite @MainActor
struct MultiConnectionSettingsTests {
    @Test(arguments: SFTPConcurrencyStrategy.allCases)
    func restrictedDisplayAndOtherEditsPreserveTheSavedStrategy(_ strategy: SFTPConcurrencyStrategy) {
        let persistence = SettingsStore(.init(strategy: strategy))
        let settings = SFTPSettingsModel(persistence: persistence)
        var requests = 0
        let access = MultiConnectionSettingsAccess(isAllowed: false) { requests += 1 }
        let selection = access.strategy(for: settings)
        #expect(selection.wrappedValue == .channelsOnly)
        #expect(persistence.saves == 0)
        selection.wrappedValue = .channelsOnly
        #expect(persistence.saves == 0)
        selection.wrappedValue = .smart
        selection.wrappedValue = .connectionsPreferred
        #expect(requests == 2)
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
