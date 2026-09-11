import Foundation
import TermindDomain

@Observable
final class KnownHostsLibraryModel {
    private let library: HostLibraryModel
    init(library: HostLibraryModel) { self.library = library }
    var entries: [KnownHostEntry] { library.knownHosts.sorted { $0.addedAt > $1.addedAt } }
    var storageError: String? { library.storageError }
    func entry(_ id: UUID) -> KnownHostEntry? { entries.first { $0.id == id } }
    func search(_ query: String) -> [KnownHostEntry] {
        entries.filter {
            query.isEmpty || $0.displayAddress.localizedCaseInsensitiveContains(query)
                || $0.fingerprint.localizedCaseInsensitiveContains(query)
                || $0.algorithm.rawValue.localizedCaseInsensitiveContains(query)
        }
    }
    func save(_ entry: KnownHostEntry) -> Bool { library.saveKnownHost(entry) }
    func delete(_ ids: Set<UUID>) -> Bool { library.deleteKnownHosts(ids) }
}
