import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileMultiHostPickerTests {
    @Test
    func metricsPickerStartsWithMonitoredHostsAndCanClearTheSelection() {
        let hosts = [Host(name: "Alpha", host: "alpha.invalid"), Host(name: "Bravo", host: "bravo.invalid")]
        let picker = MobileMultiHostPickerModel(
            library: HostLibraryModel(hosts: hosts), useCase: .metrics, selected: [hosts[0].id])

        picker.reconcileSelection()
        #expect(picker.hosts.map(\.id) == hosts.map(\.id))
        #expect(picker.orderedSelection == [hosts[0].id])
        picker.toggle(hosts[0].id)
        #expect(picker.orderedSelection.isEmpty)
    }

    @Test(arguments: [HostUseCase.metrics, .snippetExecution, .preferredTerminal, .sftp])
    func filteredSelectAllPreservesOtherSelectionsAndLibraryOrder(useCase: HostUseCase) {
        let hosts = ["Alpha", "Bravo", "Charlie"].enumerated().map { index, name in
            Host(name: name, host: "\(name.lowercased()).invalid", sortIndex: Double(index))
        }
        let picker = MobileMultiHostPickerModel(
            library: HostLibraryModel(hosts: hosts), useCase: useCase, selected: [])

        picker.toggle(hosts[2].id)
        picker.query = "Alpha"
        picker.toggleAllResults()
        #expect(picker.allResultsSelected)
        #expect(picker.orderedSelection == [hosts[0].id, hosts[2].id])
        picker.toggleAllResults()
        #expect(picker.orderedSelection == [hosts[2].id])
        #expect(!picker.allResultsSelected)
        picker.query = "missing"
        picker.toggleAllResults()
        #expect(!picker.allResultsSelected)
        #expect(picker.orderedSelection == [hosts[2].id])
        picker.query = ""
        picker.toggleAllResults()
        #expect(picker.orderedSelection == hosts.map(\.id))
        picker.toggleAllResults()
        #expect(picker.orderedSelection.isEmpty)
    }

    @Test
    func metricsExcludesMonitoredAndNonSSHHostsAndPrunesUnavailableSelections() {
        let monitored = Host(name: "Monitored", host: "monitored.invalid")
        var eligible = Host(name: "Available", host: "available.invalid")
        let telnet = Host(name: "Telnet", host: "telnet.invalid", sshEnabled: false, telnetEnabled: true)
        let library = HostLibraryModel(hosts: [monitored, eligible, telnet])
        let picker = MobileMultiHostPickerModel(
            library: library, useCase: .metrics, selected: [monitored.id, eligible.id, telnet.id, UUID()],
            isEligible: { $0.id != monitored.id })

        picker.reconcileSelection()
        #expect(picker.hosts.map(\.id) == [eligible.id])
        #expect(picker.selected == [eligible.id])
        eligible.sshEnabled = false
        eligible.telnetEnabled = true
        library.upsert(eligible)
        #expect(library.storageError == nil)
        #expect(picker.orderedSelection.isEmpty)
        picker.reconcileSelection()
        #expect(picker.selected.isEmpty)
    }

    @Test
    func batchMetricsAdditionIsAtomicAndUsesTheCurrentEntitlement() {
        let hosts = (0..<5).map { Host(name: "Host \($0)", host: "host\($0).invalid") }
        let preferences = PickerMetricsPreferences()
        let metrics = MobileMetricsModel(
            preferences: preferences, hosts: HostLibraryModel(hosts: hosts), services: .testing)
        defer { metrics.core.shutdown() }
        metrics.pause()

        #expect(metrics.add([hosts[0].id], pro: false))
        let saved = preferences.values
        #expect(!metrics.add(hosts[1...3].map(\.id), pro: false))
        #expect(preferences.values == saved)
        #expect(metrics.selections.map(\.id) == [hosts[0].id])
        #expect(metrics.add([hosts[0].id, hosts[1].id, hosts[1].id, hosts[2].id], pro: false))
        #expect(metrics.selections.count == 3)
        #expect(metrics.add(hosts[3...4].map(\.id), pro: true))
        #expect(metrics.selections.map(\.id) == hosts.map(\.id))
    }

    @Test
    func batchMetricsSaveFailureDoesNotAddAnySelections() {
        let hosts = (0..<2).map { Host(name: "Host \($0)", host: "host\($0).invalid") }
        let preferences = PickerMetricsPreferences()
        preferences.failsSaving = true
        let metrics = MobileMetricsModel(
            preferences: preferences, hosts: HostLibraryModel(hosts: hosts), services: .testing)
        defer { metrics.core.shutdown() }
        metrics.pause()

        #expect(!metrics.add(hosts.map(\.id), pro: true))
        #expect(metrics.selections.isEmpty)
        #expect(preferences.values.isEmpty)
        #expect(metrics.core.storageError != nil)
    }

    @Test
    func mobileMetricsCanSwapAtTheFreeLimitAndRemoveAllHosts() {
        let hosts = (0..<4).map { Host(name: "Host \($0)", host: "host\($0).invalid") }
        let preferences = PickerMetricsPreferences()
        let metrics = MobileMetricsModel(
            preferences: preferences, hosts: HostLibraryModel(hosts: hosts), services: .testing)
        defer { metrics.core.shutdown() }
        metrics.pause()
        #expect(metrics.add(Array(hosts.prefix(3)).map(\.id), pro: false))
        let editable = Set(hosts.map(\.id))

        #expect(
            metrics.replaceHosts(
                selectedIDs: [hosts[0].id, hosts[2].id, hosts[3].id], editableHostIDs: editable, pro: false))
        #expect(metrics.selections.map(\.id) == [hosts[0].id, hosts[2].id, hosts[3].id])
        #expect(metrics.replaceHosts(selectedIDs: [], editableHostIDs: editable, pro: false))
        #expect(metrics.selections.isEmpty)
        #expect(preferences.values.isEmpty)
    }
}

private final class PickerMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection] = []
    var failsSaving = false
    func load() -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) throws {
        if failsSaving { throw CocoaError(.fileWriteUnknown) }
        values = selections
    }
}
