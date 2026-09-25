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
    private let useCase: HostUseCase
    private let isEligible: (Host) -> Bool

    init(
        library: HostLibraryModel, useCase: HostUseCase, selected: Set<Host.ID>,
        isEligible: @escaping (Host) -> Bool = { _ in true }
    ) {
        self.library = library
        self.useCase = useCase
        self.selected = selected
        self.isEligible = isEligible
    }

    var isLibraryEmpty: Bool { library.hosts.isEmpty }
    var hosts: [Host] { library.hosts(matching: query, for: useCase).filter(isEligible) }
    var availableHostIDs: [Host.ID] { library.hosts(matching: "", for: useCase).filter(isEligible).map(\.id) }
    var orderedSelection: [Host.ID] { availableHostIDs.filter { selected.contains($0) } }
    var allResultsSelected: Bool { !hosts.isEmpty && hosts.allSatisfy { selected.contains($0.id) } }

    func loginAddress(for host: Host) -> String { library.loginAddress(for: host) }

    func reconcileSelection() { selected.formIntersection(availableHostIDs) }

    func toggle(_ id: Host.ID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    func toggleAllResults() {
        if allResultsSelected {
            selected.subtract(hosts.map(\.id))
        } else {
            selected.formUnion(hosts.map(\.id))
        }
    }
}
