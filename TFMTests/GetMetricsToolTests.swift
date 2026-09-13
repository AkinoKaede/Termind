import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@MainActor
final class TestMetricsReader: MetricsSnapshotReading {
    var value: MetricsSnapshot?
    var reads: [UUID] = []
    init(_ value: MetricsSnapshot? = nil) { self.value = value }
    func snapshot(for hostID: UUID) -> MetricsSnapshot? {
        reads.append(hostID)
        return value
    }
}

@Suite
@MainActor
struct GetMetricsToolTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func overviewAndTrendUseOnlyRecentFiniteSamples() throws {
        let old = MetricsPoint(date: now.addingTimeInterval(-301), cpu: 99)
        let first = MetricsPoint(
            date: now.addingTimeInterval(-300), cpu: 20, memory: 40, swapPercent: 50, diskRead: 100)
        let last = MetricsPoint(
            date: now, cpu: 60, memory: nil, swapPercent: 75, swapUsed: 3_072, swapTotal: 4_096,
            swapFree: 1_024, diskRead: .infinity)
        let future = MetricsPoint(date: now.addingTimeInterval(1), cpu: 100)
        let snapshot = MetricsSnapshot(capturedAt: now, state: .live, point: last, history: [future, last, old, first])
        let object = output(snapshot)
        let overview = try #require(object["overview"]?.objectValue)
        #expect(overview["cpu_percent"] == .number(60))
        #expect(overview["memory_percent"] == .null)
        #expect(overview["swap_percent"] == .number(75))
        #expect(overview["swap_used_bytes"] == .number(3_072))
        #expect(overview["swap_total_bytes"] == .number(4_096))
        #expect(overview["swap_free_bytes"] == .number(1_024))
        #expect(overview["disk_read_bytes_per_second"] == .null)
        #expect(overview["sampled_at"] == .string(now.ISO8601Format()))
        #expect(overview["age_seconds"] == .number(0))
        #expect(overview["status"] == .string("available"))
        let trend = try #require(object["trend"]?.objectValue)
        #expect(trend["sample_count"] == .number(2))
        #expect(trend["from"] == .string(first.date.ISO8601Format()))
        #expect(trend["to"] == .string(last.date.ISO8601Format()))
        #expect(trend["cpu_percent"]?.objectValue?["mean"] == .number(40))
        #expect(trend["cpu_percent"]?.objectValue?["peak"] == .number(60))
        #expect(trend["memory_percent"]?.objectValue?["sample_count"] == .number(1))
        #expect(trend["swap_percent"]?.objectValue?["mean"] == .number(62.5))
        #expect(trend["swap_percent"]?.objectValue?["peak"] == .number(75))
        #expect(trend["disk_read_bytes_per_second"]?.objectValue?["mean"] == .number(100))
        #expect(trend["network_receive_bytes_per_second"]?.objectValue?["mean"] == .null)
        for section in GetMetricsTool.sections { #expect(object[section] == nil) }
    }

    @Test
    func detailAgesFailuresAndTruncationAreIndependent() throws {
        var snapshot = MetricsSnapshot(
            capturedAt: now, state: .paused, point: MetricsPoint(date: now.addingTimeInterval(-31)))
        snapshot.gpuState = .failed
        snapshot.gpuDate = now.addingTimeInterval(-40)
        snapshot.gpu = NvidiaSnapshot(devices: [NvidiaGPU(id: "gpu", name: "NVIDIA", utilization: 80)])
        snapshot.processesDate = now.addingTimeInterval(-30)
        snapshot.processes = (1...25).map { MetricsProcess(pid: $0, started: 1, name: "worker", cpu: Double(200 - $0)) }
        snapshot.filesystemsDate = now.addingTimeInterval(-60)
        snapshot.filesystems = [
            MetricsFilesystem(mountPoint: "/", device: "/dev/vda1", type: "ext4", blockID: "8:1", used: 1024)
        ]
        let object = output(snapshot, include: GetMetricsTool.sections)
        #expect(object["status"] == .string("paused"))
        #expect(object["overview"]?.objectValue?["status"] == .string("stale"))
        #expect(object["devices"]?.objectValue?["age_seconds"] == .number(31))
        let gpu = try #require(object["gpu"]?.objectValue)
        #expect(gpu["status"] == .string("failed"))
        #expect(gpu["stale"] == .bool(true))
        #expect(gpu["age_seconds"] == .number(40))
        #expect(gpu["devices"]?.arrayValue?.first?.objectValue?["utilization_percent"] == .number(80))
        let processes = try #require(object["processes"]?.objectValue)
        #expect(processes["status"] == .string("available"))
        #expect(processes["total_count"] == .number(25))
        #expect(processes["truncated"] == .bool(true))
        #expect(processes["items"]?.arrayValue?.count == 20)
        #expect(processes["items"]?.arrayValue?.first?.objectValue?["cpu_percent"] == .number(199))
        #expect(object["filesystems"]?.objectValue?["status"] == .string("available"))
        snapshot.filesystemsDate = now.addingTimeInterval(-61)
        snapshot.processesDate = now.addingTimeInterval(-31)
        let stale = output(snapshot, include: ["filesystems", "processes"])
        #expect(stale["filesystems"]?.objectValue?["status"] == .string("stale"))
        #expect(stale["processes"]?.objectValue?["status"] == .string("stale"))
        snapshot.processesFailed = true
        snapshot.filesystemsFailed = true
        let failed = output(snapshot, include: ["filesystems", "processes"])
        #expect(failed["filesystems"]?.objectValue?["status"] == .string("failed"))
        #expect(failed["processes"]?.objectValue?["status"] == .string("failed"))
    }

    @Test
    func missingDataAndExpiredHistoryStayUnknown() {
        var snapshot = MetricsSnapshot(capturedAt: now, state: .collecting)
        snapshot.history = [MetricsPoint(date: now.addingTimeInterval(-301), cpu: 80)]
        snapshot.gpuState = .unavailable
        let object = output(snapshot, include: GetMetricsTool.sections)
        for section in ["overview", "processes", "filesystems", "devices", "gpu"] {
            #expect(object[section]?.objectValue?["status"] == .string("unavailable"))
        }
        #expect(object["overview"]?.objectValue?["cpu_percent"] == .null)
        #expect(object["trend"]?.objectValue?["from"] == .null)
        #expect(object["trend"]?.objectValue?["sample_count"] == .number(0))
        #expect(object["trend"]?.objectValue?["cpu_percent"]?.objectValue?["peak"] == .null)
        #expect(object["overview"]?.objectValue?["swap_percent"] == .null)
        #expect(object["trend"]?.objectValue?["swap_percent"]?.objectValue?["peak"] == .null)
    }

    @Test
    func zeroCapacitySwapRemainsMachineReadableWithoutAUtilization() throws {
        let snapshot = MetricsSnapshot(
            capturedAt: now, state: .live,
            point: MetricsPoint(date: now, swapUsed: 0, swapTotal: 0, swapFree: 0))
        let overview = try #require(output(snapshot)["overview"]?.objectValue)
        #expect(overview["swap_used_bytes"] == .number(0))
        #expect(overview["swap_total_bytes"] == .number(0))
        #expect(overview["swap_free_bytes"] == .number(0))
        #expect(overview["swap_percent"] == .null)
    }

    @Test
    func knownUnmonitoredAndUnknownHostsHaveDifferentOutcomes() async throws {
        let host = Host(name: "Known", host: "known.example")
        let reader = TestMetricsReader()
        let server = makeMCPServerTools(hosts: [host], metrics: reader)
        let result = try await call(server, hostID: host.id.uuidString)
        #expect(!result.isError)
        #expect(try payload(result)["status"] == .string("not_monitored"))
        #expect(reader.reads == [host.id])
        let unknown = try await call(server, hostID: UUID().uuidString)
        let invalid = try await call(server, hostID: "invalid")
        #expect(unknown.isError)
        #expect(invalid.isError)
        #expect(reader.reads == [host.id])
    }

    @Test
    func invalidIncludesAreRejectedBeforeReading() async throws {
        let host = Host(name: "Host", host: "host.example")
        let reader = TestMetricsReader()
        let server = makeMCPServerTools(hosts: [host], metrics: reader)
        for include: AgentJSONValue in [.string("gpu"), .array([.string("secrets")]), .array([.number(1)]), .null] {
            let result = try await call(server, hostID: host.id.uuidString, include: include)
            #expect(result.isError)
        }
        #expect(reader.reads.isEmpty)
    }

    @Test
    func readOnlyToolExecutesWhilePlanningWithoutApprovalOrAuthentication() async throws {
        let host = Host(name: "Host", host: "host.example")
        let reader = TestMetricsReader(
            MetricsSnapshot(capturedAt: now, state: .live, point: MetricsPoint(date: now, cpu: 42)))
        let tool = GetMetricsTool(hosts: AgentHostResolver(store: HostLibraryModel(hosts: [host])), metrics: reader)
        let call = AgentToolCall(
            id: "metrics", name: "get_metrics", arguments: .object(["host_id": .string(host.id.uuidString)]))
        let invocation = AgentToolInvocation(runID: UUID(), call: call)
        let checked = try await tool.preflight(invocation)
        #expect(checked.invocation.targetHostID == host.id)
        #expect(tool.descriptor.safety == .locallyReadOnly)
        #expect(tool.descriptor.concurrency == .parallel)
        let decision = await AgentPlanModeHook(isPlanning: true).willExecute(
            AgentToolCallContext(
                invocation: checked.invocation, descriptor: tool.descriptor, userIntent: "Inspect",
                permissionMode: .askForApproval)
        )
        #expect(decision == .proceed)
        let executor = AgentToolExecutor(
            tools: AgentToolRegistry([AnyAgentTool(tool)]),
            approval: AgentApprovalBroker(
                reviewer: nil,
                manualApproval: { _ in
                    Issue.record("Reading cached metrics must not request approval")
                    return .deny("unexpected")
                }),
            hooks: AgentLoopHooks([AgentPlanModeHook(isPlanning: true)]),
            channel: AgentEventChannel(repository: InMemoryAgentRunRepository()),
            secretBroker: SecretBroker(), userInteraction: UnavailableAgentUserInteraction(),
            runID: invocation.runID, permissionMode: .askForApproval, userIntent: "Inspect"
        )
        let result = await executor.execute(executor.plan(call))
        #expect(!result.isError)
        #expect(try payload(result)["overview"]?.objectValue?["cpu_percent"] == .number(42))
        #expect(reader.reads == [host.id])
    }

    @Test
    func mcpDisableAndReenableKeepTheSameReader() async throws {
        let host = Host(name: "Host", host: "host.example")
        let reader = TestMetricsReader()
        let hosts = AgentHostResolver(store: HostLibraryModel(hosts: [host]))
        let pool = AgentConnectionPool(
            configuration: { _ in throw MetricsReadError.output },
            routeFingerprint: { _ in throw MetricsReadError.output },
            openExec: { _ in
                Issue.record("Unexpected SSH connection")
                throw MetricsReadError.output
            },
            openSFTP: { _ in
                Issue.record("Unexpected SFTP connection")
                throw MetricsReadError.output
            }, sweepInterval: nil
        )
        let server = makeMCPServerTools(hosts: [host], metrics: reader)
        for disabled in [Set(["get_metrics"]), Set<String>()] {
            server.replaceDisabledTools(
                disabled, hosts: hosts, metrics: reader, connections: pool,
                authentication: AgentSSHAuthenticationRegistry(resolver: hosts),
                background: AgentBackgroundCommands(sweepInterval: nil))
            #expect(server.contains("get_metrics") == disabled.isEmpty)
            if !disabled.isEmpty {
                await #expect(throws: MCPServerToolsError.self) { try await call(server, hostID: host.id.uuidString) }
            }
        }
        reader.value = MetricsSnapshot(capturedAt: now, state: .sleeping)
        #expect(try payload(try await call(server, hostID: host.id.uuidString))["status"] == .string("sleeping"))
        #expect(reader.reads == [host.id])
    }

    @Test
    func persistedPresenterPreservesHostValuesAndStaleWarningAcrossLocales() throws {
        let presenter = try #require(TermindAgentTools.presenter(id: "builtin.get_metrics"))
        let snapshot = MetricsSnapshot(
            capturedAt: now, state: .live,
            point: MetricsPoint(
                date: now.addingTimeInterval(-31), cpu: 25, memory: 50, swapPercent: 75,
                swapUsed: 3_072, swapTotal: 4_096, swapFree: 1_024))
        let value = AgentJSONValue.object(output(snapshot))
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let locale = Locale(identifier: language)
            let hostLabel = AppLocalization.string("Host", locale: locale)
            let staleLabel = AppLocalization.string("Cached metrics are stale", locale: locale)
            let detail = presenter.present(
                AgentToolDetailInput(result: value, arguments: [:], locale: locale))
            #expect(detail.contains(.field(.init(label: hostLabel, value: "Host"))))
            #expect(detail.contains(.message(staleLabel, .warning)))
            #expect(detail.contains(.field(.init(label: "CPU", value: "25.0%"))))
            #expect(
                detail.contains(
                    .field(.init(label: AppLocalization.string("Swap", locale: locale), value: "75.0%"))))
        }
    }

    private func output(_ snapshot: MetricsSnapshot, include: Set<String> = []) -> [String: AgentJSONValue] {
        MetricsToolOutput.make(hostID: UUID(), name: "Host", snapshot: snapshot, include: include).objectValue ?? [:]
    }

    private func call(_ server: MCPServerTools, hostID: String, include: AgentJSONValue? = nil) async throws
        -> AgentToolResult
    {
        var arguments: [String: AgentJSONValue] = ["host_id": .string(hostID)]
        if let include { arguments["include"] = include }
        return try await server.call(
            name: "get_metrics", arguments: .object(arguments), runID: UUID(), clientName: "Tests",
            callID: UUID().uuidString, secretBroker: SecretBroker())
    }

    private func payload(_ result: AgentToolResult) throws -> [String: AgentJSONValue] {
        let json = try #require(result.untrustedPayload)
        return try #require(try AgentJSONValue.decode(Data(json.utf8)).objectValue)
    }
}
