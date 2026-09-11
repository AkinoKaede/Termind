import Foundation
import SwiftData
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileAppTests {
    @Test func startupUsesTheSharedSchemaAndEmptyRepository() throws {
        let app = try MobileAppModel(inMemory: true)
        #expect(try app.hosts.snapshot().value == .empty)
        #expect(Set(app.container.schema.entities.map(\.name)) == Set(TermindPersistence.schema.entities.map(\.name)))
        #expect(MobileTab.allCases == [.home, .metrics, .assistant, .settings])
    }

    @Test func scenesCanUseTheSameAppRepository() throws {
        let repository = InMemoryHostRepository()
        let app = try MobileAppModel(hosts: repository)
        let host = TermindDomain.Host(name: "Example", host: "example.invalid")
        try repository.upsertHost(host)
        #expect(try app.hosts.snapshot().value.hosts == [host])
    }
}

@Suite @MainActor
struct MobileWorkspaceTests {
    @Test func descriptorRoundTripContainsOnlyRestorationMetadata() throws {
        let descriptor = MobileWorkspaceDescriptor(hostID: UUID(), title: "Production", kind: .ssh)
        let data = try JSONEncoder().encode(descriptor)
        #expect(try JSONDecoder().decode(MobileWorkspaceDescriptor.self, from: data) == descriptor)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(keys.keys) == ["id", "hostID", "title", "kind"])
    }

    @Test func liveActivitiesUseStableDistinctWorkspaceDestinations() {
        let first = MobileWorkspaceDescriptor(hostID: UUID(), title: "Server", kind: .ssh)
        var renamed = first
        renamed.title = "Renamed"
        let second = MobileWorkspaceDescriptor(hostID: first.hostID, title: "Server", kind: .sftp)
        #expect(first.destinationURL == renamed.destinationURL)
        #expect(first.destinationURL != second.destinationURL)
    }

    @Test func hostEditsPersistThroughTheSharedVaultStore() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        #expect(app.library.storageError == nil)
        let store = HostPersistence(context: ModelContext(app.container))
        #expect(try store.load().hosts == app.library.hosts)
        #expect(try store.load().hosts.first?.id == host.id)
    }

    @Test func freeMetricsLimitCountsAllSelectionsAndDeduplicates() {
        let metrics = MobileMetricsModel(defaults: nil)
        let id = UUID()
        #expect(metrics.add(id, pro: false))
        #expect(metrics.add(id, pro: false))
        #expect(metrics.add(UUID(), pro: false))
        #expect(metrics.add(UUID(), pro: false))
        #expect(!metrics.add(UUID(), pro: false))
        #expect(metrics.add(UUID(), pro: true))
        #expect(metrics.selections.count == 4)
    }
}

@Suite struct WorkspaceActivityRoutingTests {
    @Test func activityBoundsItsPayloadAndKeepsTheFocusedSessionVisible() throws {
        let sessions = (0..<12).map { index in
            WorkspaceActivityAttributes.Session(
                id: UUID(), title: String(repeating: "服务器🖥️", count: 100),
                kind: "ssh", connected: index < 3)
        }
        let focused = try #require(sessions.first?.id)
        let state = WorkspaceActivityAttributes.ContentState.snapshot(sessions, focusedID: focused)
        #expect(state.workspaceCount == 12)
        #expect(state.connectedCount == 3)
        #expect(state.sessions.count == 6)
        #expect(state.sessions.first?.id == focused)
        #expect(WorkspaceActivityAttributes.workspaceID(from: state.destinationURL) == focused)
        #expect(try JSONEncoder().encode(state).count < 3500)
    }

    @Test func aggregateActivityOpensOnlyTheWorkspaceList() throws {
        #expect(WorkspaceActivityAttributes.accepts(WorkspaceActivityAttributes.destinationURL))
        for value in ["https://workspaces", "termind://workspaces/extra", "termind://workspaces?command=ls"] {
            #expect(!WorkspaceActivityAttributes.accepts(try #require(URL(string: value))))
        }
    }

    @Test func acceptsOnlyWorkspaceLinks() throws {
        let id = UUID()
        #expect(
            WorkspaceActivityAttributes.workspaceID(from: try #require(URL(string: "termind://workspace/\(id)"))) == id)
        for value in [
            "https://workspace/\(id)", "termind://workspace/not-an-id", "termind://workspace/\(id)/extra",
            "termind://workspace/\(id)?command=ls",
        ] {
            #expect(WorkspaceActivityAttributes.workspaceID(from: try #require(URL(string: value))) == nil)
        }
    }
}

@Suite struct WorkspaceHostIconTests {
    @Test func usesTheSameDistributionMatchAsTheHostList() throws {
        let catalog = try JSONDecoder().decode(
            LinuxDistributionIconCatalog.self,
            from: Data(
                #"{"entries":[{"title":"Ubuntu","asset":"LinuxDistro-ubuntu","ids":["ubuntu"],"hex":"E95420"},{"title":"Debian","asset":"LinuxDistro-debian","ids":["debian"],"hex":"A81D33"}]}"#
                    .utf8))
        let ubuntu = try #require(DetectedDistribution(id: "ubuntu", likeIDs: ["debian"]))
        #expect(catalog.entry(matching: ubuntu)?.asset == "LinuxDistro-ubuntu")
        let derivative = try #require(DetectedDistribution(id: "custom", likeIDs: ["debian"]))
        #expect(catalog.entry(matching: derivative)?.asset == "LinuxDistro-debian")
        #expect(catalog.entry(matching: try #require(DetectedDistribution(id: "unknown"))) == nil)
    }

    @Test func activityPreservesSystemArtworkAndSessionDestination() throws {
        let id = UUID()
        let session = WorkspaceActivityAttributes.Session(
            id: id, title: "Production", kind: "ssh",
            connected: true, iconAsset: "LinuxDistro-ubuntu")
        let state = WorkspaceActivityAttributes.ContentState.snapshot([session], focusedID: id)
        let restored = try JSONDecoder().decode(
            WorkspaceActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state))
        #expect(restored.sessions.first?.iconAsset == "LinuxDistro-ubuntu")
        #expect(WorkspaceActivityAttributes.workspaceID(from: restored.destinationURL) == id)
    }
}
