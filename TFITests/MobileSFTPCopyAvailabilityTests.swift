import AgentKit
import Foundation
import TermindApplication
import TermindRemoteInfrastructure
import Testing

@Suite
@MainActor
struct MobileSFTPCopyAvailabilityTests {
    @Test
    func copyIsActingOnlyAndDoesNotRequireAScratchWorkspace() throws {
        let hosts = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost }, routeFingerprint: { _ in "test" },
            openConnection: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )
        let registry = AgentToolRegistry(
            TermindAgentTools.tools(
                in: .init(
                    hosts: hosts, metrics: EmptyMetricsReader(), connections: connections
                )))
        let descriptor = try #require(registry.available(in: .acting).descriptors.first { $0.name == "sftp_copy" })
        #expect(descriptor.approvalPolicy == .ask)
        #expect(descriptor.concurrency == .sequential)
        #expect(!registry.available(in: .planning).descriptors.contains { $0.name == "sftp_copy" })
        #expect(registry.available(in: .reviewing).descriptors.isEmpty)
        #expect(TermindAgentTools.presenter(for: descriptor)?.id == "builtin.sftp_copy")
    }
}

@MainActor
private struct EmptyMetricsReader: MetricsSnapshotReading {
    func snapshot(for hostID: UUID) -> MetricsSnapshot? { nil }
}
