import Foundation
import Logging
import TermindApplication
import TermindInfrastructure
import TermindRemoteInfrastructure
import Testing

@Suite(.serialized)
struct LaunchFileLogServiceTests {
    @Test
    func disabledLoggingDoesNotCreateDirectoryOrFile() throws {
        let fixture = LogFixture()
        let service = fixture.makeService()

        service.makeLogger(label: "termind.test").error("test.event")

        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(try service.files().isEmpty)
    }

    @Test
    func labelsAndConcurrentWritesShareOneLaunchFile() async throws {
        let fixture = LogFixture()
        let service = fixture.makeService()
        try service.setSaving(true)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    service.makeLogger(label: "termind.category_\(index % 5)").info(
                        "test.event", metadata: ["attempt": "\(index)"])
                }
            }
        }

        let files = try service.files()
        #expect(files.count == 1)
        let content = try String(contentsOf: service.exportURL(for: files[0].id), encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 100)
        #expect(lines.allSatisfy { $0.contains(" test.event attempt=") })
    }

    @Test
    func disablingAndReenablingContinuesCurrentLaunchFile() throws {
        let fixture = LogFixture()
        let service = fixture.makeService()
        let logger = service.makeLogger(label: "termind.test")
        try service.setSaving(true)
        logger.info("before.disable")
        let firstID = try #require(service.files().first?.id)

        try service.setSaving(false)
        logger.info("while.disabled")
        try service.setSaving(true)
        logger.info("after.enable")

        let files = try service.files()
        #expect(files.count == 1)
        #expect(files[0].id == firstID)
        let content = try String(contentsOf: service.exportURL(for: firstID), encoding: .utf8)
        #expect(content.contains("before.disable"))
        #expect(!content.contains("while.disabled"))
        #expect(content.contains("after.enable"))
    }

    @Test
    func separateLaunchesAreNeverAutomaticallyDeleted() throws {
        let fixture = LogFixture(savingEnabled: true)
        for index in 0..<10 {
            let service = fixture.makeService(
                launchDate: Date(timeIntervalSince1970: TimeInterval(index)),
                launchID: UUID(index: index)
            )
            try service.setSaving(true)
            service.makeLogger(label: "termind.test").info("launch.event")
            try service.setSaving(false)
        }

        let service = fixture.makeService(launchID: UUID(index: 100))
        #expect(try service.files().count == 10)
    }

    @Test
    func deletingCurrentOrAllRecreatesCurrentFileWhenSaving() throws {
        let fixture = LogFixture()
        let service = fixture.makeService()
        try service.setSaving(true)
        service.makeLogger(label: "termind.test").info("test.event")
        let current = try #require(service.files().first)

        try service.delete(current.id)
        let afterSingle = try service.files()
        #expect(afterSingle.count == 1)
        #expect(afterSingle[0].id == current.id)
        #expect(afterSingle[0].byteCount == 0)

        service.makeLogger(label: "termind.test").info("test.event")
        try service.deleteAll()
        let afterAll = try service.files()
        #expect(afterAll.count == 1)
        #expect(afterAll[0].id == current.id)
        #expect(afterAll[0].byteCount == 0)
    }

    @Test
    func deletingAllWhileDisabledLeavesNoFiles() throws {
        let fixture = LogFixture()
        let service = fixture.makeService()
        try service.setSaving(true)
        service.makeLogger(label: "termind.test").info("test.event")
        try service.setSaving(false)

        try service.deleteAll()

        #expect(try service.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test
    func exportFlushesSelectedLaunchAndPreservesFilename() throws {
        let fixture = LogFixture()
        let first = fixture.makeService(launchID: UUID(index: 1))
        try first.setSaving(true)
        first.makeLogger(label: "termind.first").info("first.event")
        let firstFile = try #require(first.files().first)
        try first.setSaving(false)

        let second = fixture.makeService(launchID: UUID(index: 2))
        try second.setSaving(true)
        second.makeLogger(label: "termind.second").info("second.event")
        let exported = try second.exportURL(for: firstFile.id)

        #expect(exported.lastPathComponent == firstFile.id)
        let content = try String(contentsOf: exported, encoding: .utf8)
        #expect(content.contains("first.event"))
        #expect(!content.contains("second.event"))
    }

    @Test
    func metricsAlwaysLogsSizeButOnlyInvalidSampleLogsRedactedDetails() async throws {
        let fixture = LogFixture()
        let service = fixture.makeService()
        try service.setSaving(true)
        service.setLevel(.debug)
        let addressSentinel = "203.0.113.77"
        let metricSentinel = "metric_sentinel"
        let output = """
            __TERMIND_CPU__
            \(metricSentinel)
            __TERMIND_ADDRESSES__
            2: eth0 inet \(addressSentinel)/24
            __TERMIND_TCP__
            Tcp: RtoAlgorithm
            """
        let sampler = SSHMetricsSampler(
            session: MetricsLogExecSession(
                result: SSHExecResult(
                    stdout: output, stderr: "", exitCode: 0, stdoutTruncated: false, stderrTruncated: false)),
            logger: service.makeLogger(label: "termind.metrics")
        )

        await #expect(throws: MetricsReadError.self) { try await sampler.sample() }

        let file = try #require(service.files().first)
        let content = try String(contentsOf: service.exportURL(for: file.id), encoding: .utf8)
        #expect(content.contains("metrics.sample.collected"))
        #expect(content.contains("metrics_payload_bytes=\(output.utf8.count)"))
        #expect(content.contains(metricSentinel))
        #expect(!content.contains(addressSentinel))
        #expect(content.contains("[redacted]"))
    }
}

private final class LogFixture: @unchecked Sendable {
    let directory: URL
    nonisolated(unsafe) let defaults: UserDefaults
    private let suiteName: String

    init(savingEnabled: Bool = false) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termind-logging-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "termind.logging.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(savingEnabled, forKey: SettingsKey.loggingSavingEnabled)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeService(
        launchDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        launchID: UUID = UUID(index: 0)
    ) -> LaunchFileLogService {
        LaunchFileLogService(
            directory: directory, defaults: defaults, launchDate: launchDate, launchID: launchID)
    }
}

private actor MetricsLogExecSession: SSHMultiplexedSessionProtocol {
    let result: SSHExecResult
    init(result: SSHExecResult) { self.result = result }
    func connect(using _: SSHConnectionConfiguration) async throws {}
    func execute(
        _: String, workingDirectory _: String?, stdin _: Data?, timeout _: TimeInterval,
        outputLimit _: Int, onOutput _: SSHExecOutputHandler?
    ) async throws -> SSHExecResult { result }
    func disconnect() async {}
}

extension UUID {
    fileprivate init(index: Int) {
        self.init(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }
}
