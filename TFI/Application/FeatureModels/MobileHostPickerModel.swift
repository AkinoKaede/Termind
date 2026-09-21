import Observation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

@MainActor
@Observable
final class MobileHostPickerModel {
    var query = ""

    private let library: HostLibraryModel
    private let useCase: HostUseCase?

    init(library: HostLibraryModel, useCase: HostUseCase? = nil) {
        self.library = library
        self.useCase = useCase
    }

    var isLibraryEmpty: Bool { library.hosts.isEmpty }
    var hosts: [Host] {
        if let useCase { return library.hosts(matching: query, for: useCase) }
        return library.searchHosts(query)
    }

    func loginAddress(for host: Host) -> String { library.preferredTerminalLoginAddress(for: host) }
}

@MainActor
@Observable
final class MobileConnectionPickerModel {
    var kind = ConnectionHistoryEntry.Kind.ssh

    private let connect: (Host.ID, ConnectionHistoryEntry.Kind) -> Void

    init(connect: @escaping (Host.ID, ConnectionHistoryEntry.Kind) -> Void) {
        self.connect = connect
    }

    func select(_ host: Host) {
        let resolved: ConnectionHistoryEntry.Kind
        if kind == .ssh, host.preferredTerminalProtocol == .telnet {
            resolved = .telnet
        } else {
            resolved = kind
        }
        connect(host.id, resolved)
    }
}
