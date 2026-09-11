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

@Suite
nonisolated struct ServerMetricsParsingTests {
    @Test
    func procSectionsParseUnitsAndExcludeLoopback() throws {
        let sample = LinuxMetricsParser.parse(Self.proc)
        #expect(sample.uptime == 100)
        #expect(sample.memoryTotal == 1_048_576.0)
        #expect(sample.memoryUsed == 786_432.0)
        #expect(
            sample.disks?["nvme0n1"]
                == MetricsCounters(
                    read: 100 * 512, write: 200 * 512, readOperations: 10, writeOperations: 10, busyMilliseconds: 0,
                    readMilliseconds: 0, writeMilliseconds: 0))
        #expect(sample.interfaces?["eth0"] == MetricsCounters(read: 1000, write: 2000))
        #expect(sample.interfaces?["lo"] == nil)
    }

    @Test
    func memoryFallbackRequiresAllFieldsAndMissingSectionsStayUnknown() {
        let fallback = Self.proc.replacingOccurrences(
            of: "MemAvailable: 256 kB", with: "MemFree: 64 kB\nBuffers: 64 kB\nCached: 128 kB")
        #expect(LinuxMetricsParser.parse(fallback).memoryUsed == 786_432.0)
        let incomplete = fallback.replacingOccurrences(of: "Cached: 128 kB", with: "")
        #expect(LinuxMetricsParser.parse(incomplete).memoryUsed == nil)
        let sample = LinuxMetricsParser.parse("garbage")
        #expect(sample.cpu == nil && sample.memoryUsed == nil && sample.disks == nil && sample.uptime == nil)
    }

    @Test
    func malformedAndOverflowingCountersStayUnknown() {
        let malformed = Self.proc.replacingOccurrences(of: "100 0 100 800 0 0 0 0 90 0", with: "x 0 100 800 0 0 0 0")
            .replacingOccurrences(of: "10 0 100 0 10 0 200", with: "10 0 18446744073709551615 0 10 0 200")
        let sample = LinuxMetricsParser.parse(malformed)
        #expect(sample.cpu == nil)
        #expect(sample.disks == nil)
        #expect(sample.interfaces != nil)
    }

    @Test
    func ratesUseRemoteElapsedTimeAndDoNotDoubleCountGuest() throws {
        let old = LinuxMetricsParser.parse(Self.proc)
        var new = old
        new.uptime = 102
        new.cpu = [150, 0, 100, 850, 0, 0, 0, 0, 140, 0]
        new.disks = ["nvme0n1": MetricsCounters(read: 102 * 512, write: 204 * 512)]
        new.interfaces = ["eth0": MetricsCounters(read: 1200, write: 2400)]
        let point = MetricsCalculation.point(
            previous: old, current: new, selection: MetricsSelection(id: UUID()), date: Date())
        #expect(point.cpu == 50)
        #expect(point.diskRead == 512 && point.diskWrite == 1024)
        #expect(point.networkReceive == 100 && point.networkSend == 200)
        #expect(point.memory == 75)
    }

    @Test
    func detailBreakdownAndDeviceIOUseCounterDeltas() throws {
        let source = Self.proc.replacingOccurrences(
            of: "__TERMIND_MEMORY__",
            with:
                "cpu0 50 0 50 400 0 0 0 0\ncpu1 50 0 50 400 0 0 0 0\n__TERMIND_LOAD__\n1.2 0.8 0.5 1/10 42\n__TERMIND_MEMORY__"
        ).replacingOccurrences(of: "MemAvailable: 256 kB", with: "MemAvailable: 256 kB\nMemFree: 64 kB\nCached: 128 kB")
        let old = LinuxMetricsParser.parse(source)
        #expect(old.coreCount == 2)
        #expect(old.load == [1.2, 0.8, 0.5])
        #expect(old.memoryFree == 65_536.0)
        #expect(old.memoryCached == 131_072.0)
        var new = old
        new.uptime = 102
        new.cpu = [120, 0, 110, 850, 15, 0, 0, 5, 90, 0]
        new.disks = [
            "nvme0n1": MetricsCounters(
                read: 200 * 512, write: 400 * 512, readOperations: 30, writeOperations: 50, busyMilliseconds: 1000)
        ]
        let point = MetricsCalculation.point(
            previous: old, current: new, selection: MetricsSelection(id: UUID()), date: Date())
        #expect(point.cpuUser == 20)
        #expect(point.cpuSystem == 10)
        #expect(point.cpuWait == 15)
        #expect(point.cpuSteal == 5)
        #expect(point.cpuIdle == 50)
        let disk = try #require(point.diskDevices.first)
        #expect(disk.readIOPS == 10 && disk.writeIOPS == 20)
        #expect(disk.busy == 50)
        #expect(disk.readTotal == 102_400.0)
        #expect(point.networkDevices.first?.id == "eth0")
    }

    @Test
    func firstSampleRebootAndResetNeverProduceSpikes() {
        let old = LinuxMetricsParser.parse(Self.proc)
        var new = old
        new.uptime = 1
        let selection = MetricsSelection(id: UUID())
        for previous in [nil, old] {
            let point = MetricsCalculation.point(previous: previous, current: new, selection: selection, date: Date())
            #expect(point.cpu == nil && point.diskRead == nil && point.networkSend == nil)
            #expect(point.memory == 75)
        }
        new.uptime = 102
        new.interfaces = ["eth0": MetricsCounters(read: 1, write: 1)]
        #expect(
            MetricsCalculation.point(previous: old, current: new, selection: selection, date: Date()).networkSend == nil
        )
    }

    @Test
    func deviceSelectionsExcludeOthersAndNewDevicesNeedABaseline() {
        let old = LinuxMetricsParser.parse(Self.proc)
        var new = old
        new.uptime = 102
        new.interfaces?["new0"] = MetricsCounters(read: 999999, write: 999999)
        var selection = MetricsSelection(id: UUID())
        #expect(
            MetricsCalculation.point(previous: old, current: new, selection: selection, date: Date()).networkSend == nil
        )
        selection.interfaces = ["eth0"]
        #expect(
            MetricsCalculation.point(previous: old, current: new, selection: selection, date: Date()).networkSend == 0)
        selection.interfaces = []
        #expect(
            MetricsCalculation.point(previous: old, current: new, selection: selection, date: Date()).networkSend == nil
        )
    }

    @Test
    func nvidiaParsesMultipleStableDevicesAndKeepsDifferentMemoryMetrics() throws {
        let result = try NvidiaMetricsParser.parse(Data(Self.xml.utf8))
        #expect(result.cudaVersion == "12.4")
        #expect(result.devices.map(\.id) == ["GPU-a", "GPU-b"])
        let gpu = try #require(result.devices.first)
        #expect(gpu.memoryUsed == 1_073_741_824.0)
        #expect(gpu.memoryPercent == 25)
        #expect(gpu.memoryUtilization == 70)
        #expect(gpu.encoder == nil && gpu.fan == nil)
        #expect(result.devices.last?.utilization == nil)
    }

    @Test
    func nvidiaAllowsNoDevicesAndUnknownFields() throws {
        let result = try NvidiaMetricsParser.parse(Data("<nvidia_smi_log><unknown>x</unknown></nvidia_smi_log>".utf8))
        #expect(result.devices.isEmpty)
        let reordered = Self.xml.replacingOccurrences(of: "GPU-a", with: "GPU-z")
        #expect(try NvidiaMetricsParser.parse(Data(reordered.utf8)).devices.first?.id == "GPU-z")
    }

    @Test
    func nvidiaRejectsMalformedOversizedAndEntityPayloads() {
        for xml in [
            "<nvidia_smi_log>", "<root/>", Self.xml.replacingOccurrences(of: "GPU-b", with: "GPU-a"),
            "<!DOCTYPE nvidia_smi_log [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><nvidia_smi_log>&x;</nvidia_smi_log>",
        ] {
            #expect(throws: NvidiaMetricsError.self) { try NvidiaMetricsParser.parse(Data(xml.utf8)) }
        }
        #expect(throws: NvidiaMetricsError.self) {
            try NvidiaMetricsParser.parse(Data(repeating: 32, count: NvidiaMetricsParser.maximumBytes + 1))
        }
    }

    @Test
    func nvidiaIgnoresMIGNestedUtilizationAndInvalidValues() throws {
        let source = """
            <nvidia_smi_log><gpu><uuid>GPU-a</uuid><product_name>A</product_name>
            <utilization><gpu_util>NaN %</gpu_util><memory_util>101 %</memory_util></utilization>
            <mig_devices><gpu><utilization><gpu_util>90 %</gpu_util></utilization></gpu></mig_devices>
            </gpu></nvidia_smi_log>
            """
        let gpu = try #require(NvidiaMetricsParser.parse(Data(source.utf8)).devices.first)
        #expect(gpu.utilization == nil && gpu.memoryUtilization == nil)
    }

    static let proc = """
        __TERMIND_UPTIME__
        100.0 99.0
        __TERMIND_CPU__
        cpu 100 0 100 800 0 0 0 0 90 0
        __TERMIND_MEMORY__
        MemTotal: 1024 kB
        MemAvailable: 256 kB
        __TERMIND_DISKS__
        nvme0n1 10 0 100 0 10 0 200 0 0 0 0
        __TERMIND_NETWORK__
        eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0
        lo: 9999 0 0 0 0 0 0 0 9999 0 0 0 0 0 0 0
        """

    static let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE nvidia_smi_log SYSTEM "nvsmi_device_v12.dtd">
        <nvidia_smi_log><cuda_version>12.4</cuda_version>
        <gpu><uuid>GPU-a</uuid><product_name>RTX A</product_name><vbios_version>1.2</vbios_version>
        <fan_speed>N/A</fan_speed><fb_memory_usage><total>4096 MiB</total><used>1024 MiB</used><free>3072 MiB</free></fb_memory_usage>
        <utilization><gpu_util>55 %</gpu_util><memory_util>70 %</memory_util><encoder_util>N/A</encoder_util><decoder_util>0 %</decoder_util></utilization>
        </gpu><gpu><uuid>GPU-b</uuid><product_name>RTX B</product_name></gpu></nvidia_smi_log>
        """
}

@Suite
@MainActor
struct ServerMetricsLifecycleTests {
    @Test
    func restoredCardsAppearBeforeSlowConnectionAndRemainCancellable() async throws {
        let fixture = try Fixture()
        await fixture.sampler.holdConnection()
        fixture.preferences.selections = [MetricsSelection(id: fixture.host.id)]
        fixture.model.start()
        defer { fixture.model.shutdown() }
        let server = try #require(fixture.model.servers.first)
        #expect(server.isConnecting)
        #expect(server.point == nil)
        await eventually { await fixture.sampler.connections == 1 }
        #expect(server.isConnecting)
        let window = WindowModel()
        window.selectedDestination = .metrics
        window.openSettings()
        #expect(window.selectedDestination == .settings)
        fixture.model.setEnabled(false, for: server)
        #expect(!server.isConnecting)
        #expect(!fixture.model.keepsRunning)
        #expect(fixture.model.snapshot(for: fixture.host.id)?.state == .paused)
        await fixture.sampler.releaseConnection()
        await Task.yield()
        #expect(server.point == nil)
    }

    @Test
    func connectedStateAppearsBeforeSlowFirstSample() async throws {
        let fixture = try Fixture()
        await fixture.sampler.holdSample()
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        let server = try #require(fixture.model.servers.first)
        await eventually { await fixture.sampler.sampleWaiting }
        #expect(!server.isConnecting)
        #expect(server.point == nil)
        #expect(server.status == String(localized: "Connected — collecting metrics…"))
        await fixture.sampler.releaseSample()
        await eventually { server.point != nil }
    }

    @Test
    func navigationReturnsFromSettingsAndCreatesMetricsSelections() {
        let window = WindowModel()
        window.selectedDestination = .metrics
        window.openSettings()
        window.closeSettings()
        #expect(window.selectedDestination == .metrics)
        #expect(window.findKind == .metrics)
        #expect(window.creationActions.map(\.id) == ["metrics-server"])
        window.creationActions.first?.perform()
        #expect(window.presentations.hostChooser == .metrics)
        #expect(HostChooserPurpose.metrics.allowsMultiple)
        #expect(!HostChooserPurpose.metrics.choosesConnectionProtocol)
    }

    @Test
    func draggingReordersSelectionsWithoutRestartingOrChangingHostOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.model.shutdown() }
        let second = Host(name: "second", host: "second.example")
        let third = Host(name: "third", host: "third.example")
        fixture.hosts.upsert(second)
        fixture.hosts.upsert(third)
        fixture.model.add(fixture.host)
        fixture.model.add(second)
        fixture.model.add(third)
        await eventually { await fixture.sampler.connections == 1 }
        fixture.model.move([third.id, second.id], before: fixture.host.id)
        #expect(fixture.model.servers.map(\.id) == [second.id, third.id, fixture.host.id])
        #expect(fixture.preferences.selections.map(\.id) == [second.id, third.id, fixture.host.id])
        #expect(await fixture.sampler.connections == 1)
        fixture.model.move([second.id], before: nil)
        #expect(fixture.model.servers.map(\.id) == [third.id, fixture.host.id, second.id])
        fixture.model.move([third.id], before: third.id)
        #expect(fixture.model.servers.map(\.id) == [third.id, fixture.host.id, second.id])
    }

    @Test
    func preferencesRoundTripOnlySelections() throws {
        let name = "MetricsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MetricsPreferences(defaults: defaults)
        let selections = [MetricsSelection(id: UUID(), enabled: false, disks: [], interfaces: ["eth0"])]
        preferences.save(selections)
        #expect(preferences.load() == selections)
        let raw = try #require(defaults.data(forKey: "metrics.servers"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("password"))
    }

    @Test
    func oneWorkerSurvivesWindowsAndStopsOnPauseSleepAndRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.model.shutdown() }
        fixture.model.start()
        fixture.model.add(fixture.host)
        fixture.model.add(fixture.host)
        let server = try #require(fixture.model.servers.first)
        await eventually { server.point != nil }
        #expect(fixture.model.servers.count == 1)
        #expect(fixture.model.snapshot(for: fixture.host.id)?.state == .live)
        #expect(await fixture.sampler.connections == 1)
        let first = server.point?.date
        fixture.time.advance(2)
        await eventually { server.point?.date != first }
        #expect(await fixture.sampler.connections == 1)
        #expect(await fixture.sampler.gpuCalls == 1)  // Missing GPU probed only once.
        fixture.model.setEnabled(false, for: server)
        #expect(!fixture.model.keepsRunning)
        fixture.time.advance(2)
        await eventually { await fixture.sampler.disconnections > 0 }
        fixture.model.setEnabled(true, for: server)
        await eventually { await fixture.sampler.connections == 2 }
        fixture.model.suspend()
        #expect(fixture.model.sleeping)
        #expect(fixture.model.snapshot(for: fixture.host.id)?.state == .sleeping)
        fixture.time.advance(2)
        fixture.model.resume()
        await eventually { await fixture.sampler.connections == 3 }
        fixture.model.remove(server.id)
        #expect(fixture.model.servers.isEmpty)
        #expect(fixture.preferences.selections.isEmpty)
    }

    @Test
    func gpuFailurePreservesBaseMetricsAndHistoryExpires() async throws {
        let fixture = try Fixture()
        await fixture.sampler.failGPU()
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        let server = try #require(fixture.model.servers.first)
        await eventually { server.gpuState == .failed && !server.history.isEmpty }
        #expect(server.point?.memory == 75)
        fixture.time.advance(302)
        fixture.model.reconcile()
        #expect(server.history.isEmpty)
    }

    @Test
    func missingAuthenticationPausesUntilSubmitted() async throws {
        let fixture = try Fixture(authenticated: false)
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        let server = try #require(fixture.model.servers.first)
        await eventually { server.authenticationHost != nil }
        #expect(server.needsAttention)
        #expect(server.showsConnectionJourney)
        #expect(server.journey.phase == .waiting)
        #expect(server.journey.waitsForLocalIdentity)
        #expect(server.authenticationPrompt != nil)
        #expect(fixture.model.snapshot(for: fixture.host.id)?.state == .awaitingAuthentication)
        #expect(await fixture.sampler.connections == 0)
        fixture.model.submitAuthentication(
            server, identityID: nil, username: "root", password: "test-only", passphrase: nil, keyID: nil, save: false)
        await eventually { server.point != nil }
        #expect(!server.needsAttention)
        #expect(await fixture.sampler.connections == 1)
    }

    @Test
    func verificationUsesJourneyAndTemporaryTrustStaysScopedToTheMonitor() async throws {
        let fixture = try Fixture(trusted: false)
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        let server = try #require(fixture.model.servers.first)
        await eventually { server.hostKeyPrompt != nil }
        #expect(server.requiresAuthentication && server.showsConnectionJourney)
        #expect(server.journey.purpose == .metrics)
        #expect(server.journey.phase == .waiting)
        #expect(server.journey.checkpoint?.kind == .hostKey)
        #expect(await fixture.sampler.connections == 0)
        let observation = try #require(server.hostKey)
        fixture.model.acceptHostKey(server, observation: observation, remember: false)
        await eventually { server.point != nil }
        #expect(fixture.hosts.knownHosts(for: fixture.host).isEmpty)
        #expect(await fixture.sampler.lastConfiguration?.expectedHostKeys.contains(observation.identity) == true)
        #expect(server.journey.phase == .succeeded)
        fixture.model.setEnabled(false, for: server)
        fixture.model.setEnabled(true, for: server)
        await eventually { server.hostKey != nil }
        #expect(await fixture.sampler.connections == 1)
    }

    @Test
    func rejectingOrUsingAnOutdatedKeyNeverOpensTransport() async throws {
        let fixture = try Fixture(trusted: false)
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        let server = try #require(fixture.model.servers.first)
        await eventually { server.hostKey != nil }
        var wrong = try #require(server.hostKey)
        wrong.fingerprint = "SHA256:outdated"
        fixture.model.acceptHostKey(server, observation: wrong, remember: true)
        #expect(fixture.hosts.knownHosts(for: fixture.host).isEmpty)
        #expect(await fixture.sampler.connections == 0)
        fixture.model.setEnabled(false, for: server)
        #expect(!server.journey.isPresented)
        #expect(!server.selection.enabled)
    }

    @Test
    func explicitTrustPersistsAndCompletesJourney() async throws {
        let fixture = try Fixture(trusted: false)
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        let server = try #require(fixture.model.servers.first)
        await eventually { server.hostKey != nil }
        let observation = try #require(server.hostKey)
        fixture.model.acceptHostKey(server, observation: observation, remember: true)
        await eventually { server.point != nil }
        #expect(fixture.hosts.knownHosts(for: fixture.host).map(\.identity) == [observation.identity])
        #expect(!server.requiresAuthentication)
        #expect(server.journey.phase == .succeeded)
    }

    @Test
    func processCollectionIsSharedAndOnlyRunsForObservedDetails() async throws {
        let fixture = try Fixture()
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        let server = try #require(fixture.model.servers.first)
        await eventually { !fixture.time.delays.isEmpty }
        #expect(await fixture.sampler.processCalls == 0)
        let first = UUID()
        let second = UUID()
        fixture.model.observeDetails(hostID: server.id, observer: first)
        fixture.model.observeDetails(hostID: server.id, observer: second)
        await fixture.sampler.failProcesses()
        fixture.time.advance(2)
        await eventually { server.processesFailed }
        #expect(await fixture.sampler.processCalls == 1)
        #expect(server.point?.memory == 75)
        fixture.model.stopObservingDetails(first)
        fixture.model.stopObservingDetails(second)
        await eventually { fixture.time.delays.count >= 2 }
        fixture.time.advance(2)
        await eventually { fixture.time.delays.count >= 3 }
        #expect(await fixture.sampler.processCalls == 1)
    }

    @Test
    func connectionFailureUsesExponentialBackoff() async throws {
        let fixture = try Fixture()
        await fixture.sampler.failConnection()
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        await eventually { fixture.time.delays.contains(2) }
        fixture.time.advance(2)
        await eventually { fixture.time.delays.contains(4) }
        fixture.time.advance(4)
        await eventually { fixture.time.delays.contains(8) }
    }

    @Test
    func changingHostConfigurationRestartsConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.model.shutdown() }
        fixture.model.add(fixture.host)
        await eventually { await fixture.sampler.connections == 1 }
        fixture.model.reconcile()
        fixture.model.reconcile()
        #expect(await fixture.sampler.connections == 1)
        var host = fixture.host
        host.port = 2222
        fixture.hosts.trust(KnownHostEntry(hostname: host.host, port: 2222, fingerprint: "SHA256:test"))
        fixture.hosts.upsert(host)
        fixture.model.reconcile()
        await eventually { await fixture.sampler.connections == 2 }
    }

    private func eventually(_ condition: () async -> Bool) async {
        for _ in 0..<2000 {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await condition())
    }

    private struct Fixture {
        let host: TermindDomain.Host
        let hosts: HostLibraryModel
        let sampler = FakeMetricsSampler()
        let time = ManualMetricsTime()
        let preferences = MemoryMetricsPreferences()
        let model: ServerMetricsModel
        init(authenticated: Bool = true, trusted: Bool = true) throws {
            let identity = Identity(name: "test", username: "root")
            var host = Host(name: "test", host: "test.example")
            if authenticated { host.identityID = identity.id }
            self.host = host
            hosts = HostLibraryModel(
                hosts: [host],
                knownHosts: trusted ? [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")] : [])
            if authenticated { try hosts.upsert(identity, passwordUpdate: .replace("test-only")) }
            let sampler = sampler
            model = ServerMetricsModel(
                hosts: hosts, preferences: preferences, makeSampler: { sampler },
                discover: { host, _, _ in
                    SSHHostKeyObservation(
                        hostname: host.host, port: host.port, algorithm: .ed25519, fingerprint: "SHA256:test")
                }, clock: time.clock
            )
        }
    }
}

private final class MemoryMetricsPreferences: MetricsConfigurationStoring {
    var selections: [MetricsSelection] = []
    func load() -> [MetricsSelection] { selections }
    func save(_ selections: [MetricsSelection]) { self.selections = selections }
}

private actor FakeMetricsSampler: MetricsSampling {
    private var connectionHeld = false
    private var sampleHeld = false
    private var connectionContinuation: CheckedContinuation<Void, Never>?
    private var sampleContinuation: CheckedContinuation<Void, Never>?
    var sampleWaiting: Bool { sampleContinuation != nil }
    func holdConnection() { connectionHeld = true }
    func holdSample() { sampleHeld = true }
    func releaseConnection() {
        connectionHeld = false
        connectionContinuation?.resume()
        connectionContinuation = nil
    }
    func releaseSample() {
        sampleHeld = false
        sampleContinuation?.resume()
        sampleContinuation = nil
    }
    var connections = 0
    var lastConfiguration: SSHConnectionConfiguration?
    var disconnections = 0
    var gpuCalls = 0
    var processCalls = 0
    private var processError = false
    func failProcesses() { processError = true }
    func processes() async throws -> MetricsProcessSample? {
        processCalls += 1
        if processError { throw MetricsReadError.output }
        return nil
    }
    private var samples = 0
    private var gpuError = false
    private var connectionError = false
    func failGPU() { gpuError = true }
    func failConnection() { connectionError = true }
    func connect(_ configuration: SSHConnectionConfiguration) async throws {
        connections += 1
        lastConfiguration = configuration
        if connectionHeld { await withCheckedContinuation { connectionContinuation = $0 } }
        if connectionError { throw TermindSSHError.disconnected }
    }
    func disconnect() async { disconnections += 1 }
    func sample() async throws -> MetricsSample {
        samples += 1
        if sampleHeld { await withCheckedContinuation { sampleContinuation = $0 } }
        var sample = LinuxMetricsParser.parse(ServerMetricsParsingTests.proc)
        sample.uptime = Double(samples * 2)
        return sample
    }
    func gpu() async throws -> NvidiaSnapshot? {
        gpuCalls += 1
        if gpuError { throw MetricsReadError.output }
        return nil
    }
}

/// A cancellation-aware manual clock. Advancing releases only already-registered sleeps.
private nonisolated final class ManualMetricsTime: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    private var waiters: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    private var requested: [Double] = []
    var delays: [Double] { lock.withLock { requested } }
    var clock: MetricsClock {
        MetricsClock(now: { self.lock.withLock { self.date } }, sleep: { try await self.sleep($0) })
    }
    func advance(_ seconds: Double) {
        let ready = lock.withLock {
            date.addTimeInterval(seconds)
            let ready = waiters.filter { $0.value.0 <= date }
            for id in ready.keys { waiters[id] = nil }
            return ready.values.map { $0.1 }
        }
        for waiter in ready { waiter.resume() }
    }
    private func sleep(_ seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    requested.append(seconds)
                    waiters[id] = (date.addingTimeInterval(seconds), continuation)
                }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id)?.1 }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
