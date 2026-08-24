import Foundation

/// Application-wide host projection shared by every window. Selection and
/// navigation remain window state; persistent host data does not.
@Observable
final class HostLibraryModel {
    private(set) var snapshot: HostLibrarySnapshot = .empty
    private(set) var revision: Int64 = -1
    private(set) var errorMessage: String?

    private let repository: any HostRepository
    private var observationTask: Task<Void, Never>?

    init(repository: any HostRepository) {
        self.repository = repository
        observationTask = Task { [weak self, repository] in
            for await change in repository.changes() {
                guard !Task.isCancelled else { return }
                self?.apply(change)
            }
        }
    }

    var hosts: [Host] { snapshot.hosts }
    var groups: [HostGroup] { snapshot.groups }

    func refresh() {
        do {
            try repository.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ change: RepositoryChange<HostLibrarySnapshot>) {
        guard change.revision >= revision else { return }
        revision = change.revision
        snapshot = change.value
        errorMessage = nil
    }
}
