import Foundation
import Observation
import SwiftData
import TermindApplication
import TermindInfrastructure
import TermindPersistence

/// App-owned services are shared by every scene; selection belongs to each scene.
@MainActor
@Observable
final class MobileAppModel {
    let container: ModelContainer
    let hosts: any HostRepository

    init(hosts: any HostRepository = InMemoryHostRepository()) throws {
        container = try TermindPersistence.makeContainer(inMemory: true)
        self.hosts = hosts
    }
}

nonisolated enum MobileDestination: String, CaseIterable, Identifiable {
    case hosts, assistant, settings
    var id: Self { self }
}
