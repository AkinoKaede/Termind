import Observation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

@MainActor
@Observable
final class MobileMultiHostPickerModel {
    var query = ""
    private(set) var selected: Set<Host.ID>

    private let library: HostLibraryModel
    private var useCase: HostUseCase
    private let isEligible: (Host) -> Bool
    let isSelectable: (Host) -> Bool

    init(
        library: HostLibraryModel, useCase: HostUseCase, selected: Set<Host.ID>,
        isEligible: @escaping (Host) -> Bool = { _ in true },
        isSelectable: @escaping (Host) -> Bool = { _ in true }
    ) {
        self.library = library
        self.useCase = useCase
        self.selected = selected
        self.isEligible = isEligible
        self.isSelectable = isSelectable
    }

    var isLibraryEmpty: Bool { library.hosts.isEmpty }
    var hosts: [Host] { library.hosts(matching: query, for: useCase).filter(isEligible) }
    var availableHostIDs: [Host.ID] { library.hosts(matching: "", for: useCase).filter(isEligible).map(\.id) }
    var orderedSelection: [Host.ID] { availableHostIDs.filter { selected.contains($0) } }
    var selectableHosts: [Host] { hosts.filter(isSelectable) }
    var allResultsSelected: Bool { !selectableHosts.isEmpty && selectableHosts.allSatisfy { selected.contains($0.id) } }

    func loginAddress(for host: Host) -> String {
        if useCase == .preferredTerminal { return library.preferredTerminalLoginAddress(for: host) }
        return library.loginAddress(for: host)
    }

    func updateUseCase(_ useCase: HostUseCase) {
        self.useCase = useCase
        reconcileSelection()
    }

    func reconcileSelection() { selected.formIntersection(availableHostIDs) }

    func toggle(_ id: Host.ID) {
        guard selectableHosts.contains(where: { $0.id == id }) else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    func toggleAllResults() {
        if allResultsSelected {
            selected.subtract(selectableHosts.map(\.id))
        } else {
            selected.formUnion(selectableHosts.map(\.id))
        }
    }
}
