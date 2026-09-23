import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

nonisolated private struct InertSerialConnection: SerialPortConnection {
    func write(_: Data) async throws {}
    func close() async {}
}

nonisolated private struct InertSerialService: SerialPortServing {
    func availablePorts() async -> [SerialPortDescriptor] { [] }
    func portUpdates() -> AsyncStream<[SerialPortDescriptor]> {
        AsyncStream { $0.finish() }
    }
    func open(
        _: SerialConnectionConfiguration,
        receive _: @escaping @Sendable (Data) -> Void,
        disconnected _: @escaping @Sendable (String) -> Void,
        progress _: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) async throws -> any SerialPortConnection {
        InertSerialConnection()
    }
}

nonisolated private struct EmittingSerialService: SerialPortServing {
    let data: Data

    func availablePorts() async -> [SerialPortDescriptor] { [] }
    func portUpdates() -> AsyncStream<[SerialPortDescriptor]> {
        AsyncStream { $0.finish() }
    }
    func open(
        _: SerialConnectionConfiguration,
        receive: @escaping @Sendable (Data) -> Void,
        disconnected _: @escaping @Sendable (String) -> Void,
        progress _: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) async throws -> any SerialPortConnection {
        receive(data)
        return InertSerialConnection()
    }
}

nonisolated private final class RecordingSerialConnection: SerialPortConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var storedWrites: [Data] = []

    var writes: [Data] { lock.withLock { storedWrites } }

    func write(_ data: Data) async throws { lock.withLock { storedWrites.append(data) } }
    func close() async {}
}

nonisolated private struct RecordingSerialService: SerialPortServing {
    let connection: RecordingSerialConnection

    func availablePorts() async -> [SerialPortDescriptor] { [] }
    func portUpdates() -> AsyncStream<[SerialPortDescriptor]> {
        AsyncStream { $0.finish() }
    }
    func open(
        _: SerialConnectionConfiguration,
        receive _: @escaping @Sendable (Data) -> Void,
        disconnected _: @escaping @Sendable (String) -> Void,
        progress _: @escaping @Sendable (SerialPortOpenStage) -> Void
    ) async throws -> any SerialPortConnection {
        connection
    }
}

@Suite
struct SerialFeatureTests {
    @Test
    func defaultConfigurationIs9600EightNOneWithRawCarriageReturn() {
        var configuration = SerialConnectionConfiguration()
        configuration.devicePath = "/dev/ttyUSB0"

        #expect(configuration.isValid)
        #expect(configuration.summary == "9600 8-N-1")
        #expect(configuration.flowControl == .none)
        #expect(configuration.enterKey == .carriageReturn)
        #expect(!configuration.localEcho)
        #expect(configuration.charset == .utf8)
        #expect(configuration.transformInteractiveInput(Data("a\r".utf8)) == Data("a\r".utf8))
    }

    @Test
    func enterMappingChangesOnlyCarriageReturnBytes() {
        var configuration = SerialConnectionConfiguration()
        configuration.enterKey = .lineFeed
        #expect(
            configuration.transformInteractiveInput(Data([0x41, 0x0D, 0x42, 0x0A])) == Data([0x41, 0x0A, 0x42, 0x0A]))

        configuration.enterKey = .carriageReturnLineFeed
        #expect(configuration.transformInteractiveInput(Data([0x0D])) == Data([0x0D, 0x0A]))
    }

    @Test
    func validationAcceptsCustomAbsolutePathsAndRejectsBadBaudRates() {
        var configuration = SerialConnectionConfiguration(devicePath: " /dev/ttyACM0 ")
        #expect(configuration.isValid)
        #expect(configuration.normalizedDevicePath == "/dev/ttyACM0")

        configuration.baudRate = 0
        #expect(!configuration.isValid)
        configuration.baudRate = 4_000_001
        #expect(!configuration.isValid)
    }

    @MainActor
    @Test
    func editableComboKeepsTypedValuesAndPresetMetadataDistinct() {
        let option = SerialComboOption(value: "/dev/cu.usbserial-01", label: "USB UART — /dev/cu.usbserial-01")
        #expect(option.id == option.value)
        #expect(option.label.contains(option.value))

        let rates = SerialConnectionConfiguration.commonBaudRates.map(String.init)
        #expect(rates.contains("115200"))
        #expect(rates.contains("4000000"))
    }

    @Test
    func discoveryCollapsesCalloutAndDialInAliasesWithoutHidingCustomTTYPaths() {
        let ports = SerialPortDiscovery.deduplicated([
            SerialPortDescriptor(path: "/dev/tty.usbserial-01", name: "USB UART"),
            SerialPortDescriptor(path: "/dev/cu.usbserial-01", name: "USB UART"),
            SerialPortDescriptor(path: "/dev/cu.usbserial-01", name: "USB UART"),
            SerialPortDescriptor(path: "/dev/ttyUSB0", name: "ttyUSB0"),
        ])

        #expect(ports.map(\.path) == ["/dev/cu.usbserial-01", "/dev/ttyUSB0"])
    }

    @MainActor
    @Test
    func serialConnectionUsesTheSharedConnectionJourney() {
        let journey = ConnectionJourney()
        journey.beginSerial(name: "USB UART", address: "/dev/cu.usbserial-01")

        #expect(journey.purpose == .serialSession)
        #expect(journey.phase == .connecting)
        #expect(journey.endpoints.count == 2)
        #expect(journey.destination?.name == "USB UART")
        #expect(journey.destination?.address == "/dev/cu.usbserial-01")

        journey.fail("Device busy")
        #expect(journey.phase == .failed("Device busy"))
    }

    @MainActor
    @Test
    func serialReceiveBypassesInvalidUTF8WithoutDisconnecting() async {
        let configuration = SerialConnectionConfiguration(devicePath: "/dev/ttyUSB0", charset: .utf8)
        let session = SerialSessionModel(
            configuration: configuration,
            service: EmittingSerialService(data: Data([0x41, 0xFF, 0x42]))
        )

        session.prepareForReopen()
        session.connectIfNeeded()
        for _ in 0..<10 { await Task.yield() }

        #expect(session.status == .connected)
        session.disconnect()
    }

    @MainActor
    @Test
    func serialSendBypassesUnrepresentableUTF8WithoutDisconnecting() async {
        let connection = RecordingSerialConnection()
        let configuration = SerialConnectionConfiguration(
            devicePath: "/dev/ttyUSB0", charset: .isoLatin1)
        let session = SerialSessionModel(
            configuration: configuration,
            service: RecordingSerialService(connection: connection)
        )

        session.prepareForReopen()
        session.connectIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        session.handleTerminalWrite(Data("café🙂".utf8), interactive: false)
        for _ in 0..<10 { await Task.yield() }

        #expect(connection.writes == [Data([0x63, 0x61, 0x66, 0xE9]) + Data("🙂".utf8)])
        #expect(session.status == .connected)
        session.disconnect()
    }

    @MainActor
    @Test
    func serialPaneParticipatesInSessionsAndFindButCannotBeDuplicated() {
        let configuration = SerialConnectionConfiguration(
            devicePath: "/dev/ttyUSB0", deviceName: "USB UART"
        )
        let pane = Pane.serialSession(configuration: configuration, service: InertSerialService())
        let workspace = Workspace(pane: pane)
        let window = WindowModel(workspaces: [workspace])
        window.select(workspace.id)

        #expect(pane.kind == .serialSession)
        #expect(pane.serialSession?.title == "USB UART")
        #expect(window.sessionPanes.map(\.pane.id) == [pane.id])
        #expect(window.serialSessionPanes.map(\.pane.id) == [pane.id])
        #expect(window.canFindInTerminal)
        #expect(window.canSplitSelected)
        #expect(!window.canDuplicateSelected)
    }
}
