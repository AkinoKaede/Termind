import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure
import Testing

@Suite
struct SSHMetricsSamplerTests {
    @Test
    func structuredMetricsIgnoreRemoteShellPreambleAndTrailer() async throws {
        let session = FramedMetricsSession(results: [
            Self.result(framing: Self.primaryPayload),
            Self.result(framing: Self.filesystemPayload),
            Self.result(framing: Self.processPayload),
            Self.result(framing: Self.gpuPayload),
        ])
        let sampler = SSHMetricsSampler(connection: session)

        let sample = try await sampler.sample()
        #expect(sample.uptime == 100)
        #expect(sample.cpu?.first == 100)

        let filesystems = try #require(try await sampler.filesystems())
        #expect(filesystems.first?.mountPoint == "/")
        #expect(filesystems.first?.total == 2_097_152)

        let processes = try #require(try await sampler.processes())
        #expect(processes.coreCount == 1)
        #expect(processes.processes.first?.pid == 42)

        let gpu = try #require(try await sampler.gpu())
        #expect(gpu.devices.first?.id == "GPU-test")

        let commands = await session.executedCommands
        #expect(commands.count == 4)
        #expect(commands.allSatisfy { $0.contains(Self.begin) && $0.contains(Self.end) })
        #expect(commands.allSatisfy { $0.contains("__termind_metrics_status") })
    }

    @Test
    func missingTruncatedAndOversizedFramesRemainFailures() async {
        let missing = SSHMetricsSampler(
            connection: FramedMetricsSession(results: [
                SSHExecResult(
                    stdout: Self.primaryPayload, stderr: "", exitCode: 0,
                    stdoutTruncated: false, stderrTruncated: false)
            ]))
        await #expect(throws: MetricsReadError.self) { try await missing.sample() }

        let truncated = SSHMetricsSampler(
            connection: FramedMetricsSession(results: [
                SSHExecResult(
                    stdout: Self.framed(Self.primaryPayload), stderr: "", exitCode: 0,
                    stdoutTruncated: true, stderrTruncated: false)
            ]))
        await #expect(throws: MetricsReadError.self) { try await truncated.sample() }

        let oversizedPayload = Self.primaryPayload + String(repeating: "x", count: 262_144)
        let oversized = SSHMetricsSampler(
            connection: FramedMetricsSession(results: [Self.result(framing: oversizedPayload)]))
        await #expect(throws: MetricsReadError.self) { try await oversized.sample() }
    }

    @Test
    func specialAndNonzeroExitCodesKeepTheirMeaning() async throws {
        let unsupported = SSHMetricsSampler(
            connection: FramedMetricsSession(results: [Self.result(exitCode: 42)]))
        do {
            _ = try await unsupported.sample()
            Issue.record("Expected unsupported metrics")
        } catch MetricsReadError.unsupported {
        } catch {
            Issue.record("Expected MetricsReadError.unsupported, received \(error)")
        }

        let gpuSession = FramedMetricsSession(results: [
            Self.result(exitCode: 42), Self.result(exitCode: 6), Self.result(exitCode: 1),
        ])
        let gpuSampler = SSHMetricsSampler(connection: gpuSession)
        #expect(try await gpuSampler.gpu() == nil)
        #expect(try await gpuSampler.gpu() == nil)
        await #expect(throws: MetricsReadError.self) { try await gpuSampler.gpu() }
    }

    private static let begin = "__TERMIND_METRICS_BEGIN__"
    private static let end = "__TERMIND_METRICS_END__"

    private static func framed(_ payload: String) -> String {
        "\u{1B}]7;file://instance/home/ubuntu\u{07}" + begin + "\n" + payload + "\n" + end
            + "\n\u{1B}]7;file://instance/home/ubuntu\u{07}"
    }

    private static func result(framing payload: String = "", exitCode: Int32 = 0) -> SSHExecResult {
        SSHExecResult(
            stdout: framed(payload), stderr: "", exitCode: exitCode,
            stdoutTruncated: false, stderrTruncated: false)
    }

    private static let primaryPayload = """
        __TERMIND_UPTIME__
        100.0 200.0
        __TERMIND_CPU__
        cpu 100 0 100 800 0 0 0 0
        cpu0 100 0 100 800 0 0 0 0
        """

    private static let filesystemPayload = """
        24 1 8:1 / / rw - ext4 /dev/sda1 rw
        __TERMIND_DF__
        Filesystem Type 1024-blocks Used Available Capacity Mounted on
        /dev/sda1 ext4 2048 1024 1024 50% /
        """

    private static let processPayload = """
        cpu 100 0 0 900 0 0 0 0
        cpu0 100 0 0 900 0 0 0 0
        pagesize 4096
        __TERMIND_PROCESSES__
        42 (worker) R 0 0 0 0 0 0 0 0 0 0 10 5 0 0 0 0 0 0 100 0 25
        """

    private static let gpuPayload = """
        <?xml version="1.0"?>
        <nvidia_smi_log><gpu><uuid>GPU-test</uuid><product_name>Test GPU</product_name></gpu></nvidia_smi_log>
        """
}

private actor FramedMetricsSession: SSHConnectionProtocol {
    private var results: [SSHExecResult]
    private(set) var executedCommands: [String] = []

    init(results: [SSHExecResult]) { self.results = results }

    func connect(using _: SSHConnectionConfiguration) async throws {}

    func execute(
        _ command: String, workingDirectory _: String?, stdin _: Data?, timeout _: TimeInterval,
        outputLimit _: Int, onOutput _: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        executedCommands.append(command)
        guard !results.isEmpty else { throw MetricsReadError.output }
        return results.removeFirst()
    }

    func openSFTPChannel() async throws -> any SFTPChannelProtocol { throw SFTPError.notConnected }
    func disconnect() async {}
}
