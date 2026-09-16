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
            openExec: { _ in throw AgentToolError.invalidHost }, openSFTP: { _ in throw AgentToolError.invalidHost },
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

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func copyApprovalLabelsAndOverwriteWarningUseAppResources(_ language: String) {
        let items = SFTPCopyTool.presentArguments(
            .init(
                arguments: [
                    "source_host_id": .string("source"), "destination_host_id": .string("destination"),
                    "conflict_policy": .string("replace"),
                ], locale: Locale(identifier: language)
            ))
        let label = language == "en" ? "Source host" : language == "zh-Hant" ? "來源主機" : "源主机"
        #expect(
            items.contains {
                if case .field(let field) = $0 { return field.label == label }
                return false
            })
        #expect(
            items.contains {
                if case .message(_, .warning) = $0 { return true }
                return false
            })
    }
}

@MainActor
private struct EmptyMetricsReader: MetricsSnapshotReading {
    func snapshot(for hostID: UUID) -> MetricsSnapshot? { nil }
}
