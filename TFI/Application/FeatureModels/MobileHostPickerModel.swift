import Observation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

@MainActor
@Observable
final class MobileHostPickerModel {
    var query = ""

    private let library: HostLibraryModel

    init(library: HostLibraryModel) { self.library = library }

    var isLibraryEmpty: Bool { library.hosts.isEmpty }
    var hosts: [Host] { library.searchHosts(query) }

    func loginAddress(for host: Host) -> String { library.loginAddress(for: host) }
}

@MainActor
@Observable
final class MobileConnectionPickerModel {
    var kind = ConnectionHistoryEntry.Kind.ssh

    private let connect: (Host.ID, ConnectionHistoryEntry.Kind) -> Void

    init(connect: @escaping (Host.ID, ConnectionHistoryEntry.Kind) -> Void) {
        self.connect = connect
    }

    func select(_ host: Host) { connect(host.id, kind) }
}
