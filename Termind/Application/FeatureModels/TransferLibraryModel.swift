import Foundation

/// Saved-vault access exposed to transfer presentation and session entry points.
@Observable
final class TransferLibraryModel {
    let library: HostLibraryModel

    init(library: HostLibraryModel) {
        self.library = library
    }

    func host(_ id: Host.ID) -> Host? { library.host(id) }
}
