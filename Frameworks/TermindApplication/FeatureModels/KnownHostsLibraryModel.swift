// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@Observable
public final class KnownHostsLibraryModel {
    private let library: HostLibraryModel
    public init(library: HostLibraryModel) { self.library = library }
    public var entries: [KnownHostEntry] { library.knownHosts.sorted { $0.addedAt > $1.addedAt } }
    public var storageError: String? { library.storageError }
    public func entry(_ id: UUID) -> KnownHostEntry? { entries.first { $0.id == id } }
    public func search(_ query: String) -> [KnownHostEntry] {
        entries.filter {
            query.isEmpty || $0.displayAddress.localizedCaseInsensitiveContains(query)
                || $0.fingerprint.localizedCaseInsensitiveContains(query)
                || $0.algorithm.rawValue.localizedCaseInsensitiveContains(query)
        }
    }
    public func save(_ entry: KnownHostEntry) -> Bool { library.saveKnownHost(entry) }
    public func delete(_ ids: Set<UUID>) -> Bool { library.deleteKnownHosts(ids) }
}
