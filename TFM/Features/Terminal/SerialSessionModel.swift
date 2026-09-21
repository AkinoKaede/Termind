import Combine
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

@MainActor
private final class SerialSessionRelay {
    weak var owner: SerialSessionModel?
    let inputCapture = TerminalInteractiveInputCapture()
    let decoder: RemoteCharsetStreamConverter

    init(charset: RemoteCharset) {
        decoder = try! RemoteCharsetStreamConverter(charset: charset, direction: .decoding)
    }
}

nonisolated private final class WeakSerialSessionReference: @unchecked Sendable {
    weak var owner: SerialSessionModel?
    init(_ owner: SerialSessionModel) { self.owner = owner }
}

/// One temporary serial terminal. Ghostty owns emulation and scrollback; the
/// serial service owns only device discovery and byte transport.
@Observable
final class SerialSessionModel: Identifiable {
    let id = UUID()
    private(set) var configuration: SerialConnectionConfiguration
    var status: ConnectionStatus = .disconnected
    var hasUnreadOutput = false
    var charsetError: String?
    @ObservationIgnored lazy var find = TerminalFindController(
        perform: { [weak self] in self?.performFind($0) },
        focus: { [weak self] in self?.requestTerminalFocus() }
    )

    let terminalState: TerminalViewState
    #if canImport(AppKit)
        let terminalViewOwner: PersistentTerminalViewOwner
    #endif
    private let terminalBackend: InMemoryTerminalSession
    private let service: any SerialPortServing
    private let relay: SerialSessionRelay
    private let inputConverter: RemoteCharsetStreamConverter
    private let outputConverter: RemoteCharsetStreamConverter
    private var connection: (any SerialPortConnection)?
    private var connectionTask: Task<Void, Never>?
    private var startsOnMount = true
    let connectionController = RemoteSessionConnectionController()
    var connectionJourney: ConnectionJourney { connectionController.journey }

    var title: String {
        if let name = configuration.deviceName, !name.isEmpty { return name }
        return URL(fileURLWithPath: configuration.normalizedDevicePath).lastPathComponent
    }
    var devicePath: String { configuration.normalizedDevicePath }
    var subtitle: String { "\(devicePath) · \(configuration.summary)" }

    init(configuration: SerialConnectionConfiguration, service: any SerialPortServing) {
        self.configuration = configuration
        self.service = service
        let relay = SerialSessionRelay(charset: configuration.charset)
        self.relay = relay
        inputConverter = try! RemoteCharsetStreamConverter(charset: configuration.charset, direction: .encoding)
        outputConverter = relay.decoder
        let backend = InMemoryTerminalSession(
            write: { data in
                let interactive = relay.inputCapture.classifyWrite(data)
                Task { @MainActor in relay.owner?.handleTerminalWrite(data, interactive: interactive) }
            },
            resize: { _ in },
            suppressesPixelOnlyResizes: true
        )
        let state = TerminalViewState(configSource: .none)
        state.configuration = TerminalSurfaceOptions(
            backend: .inMemory(backend), resizeThrottleMilliseconds: 35
        )
        terminalBackend = backend
        terminalState = state
        #if canImport(AppKit)
            terminalViewOwner = PersistentTerminalViewOwner(
                state: state, inputCapture: relay.inputCapture
            )
        #endif
        relay.owner = self
        // Present the shared Journey before SwiftUI mounts the pane, preventing
        // a one-frame flash of the empty Ghostty surface before `onAppear`
        // starts the actual open attempt.
        connectionJourney.beginSerial(name: title, address: devicePath)
    }

    func prepareForReopen() {
        startsOnMount = true
        status = .connecting
    }

    func connectIfNeeded() {
        guard startsOnMount, status == .connecting else { return }
        connect()
    }

    func connect() {
        startsOnMount = false
        charsetError = nil
        connectionTask?.cancel()
        let previousConnection = connection
        connection = nil
        status = .connecting
        connectionJourney.beginSerial(name: title, address: devicePath)
        let service = service
        let configuration = configuration
        let backend = terminalBackend
        let decoder = outputConverter
        let reference = WeakSerialSessionReference(self)
        connectionTask = Task { [weak self] in
            do {
                if let previousConnection { await previousConnection.close() }
                let opened = try await service.open(
                    configuration,
                    receive: { data in
                        do {
                            let converted = try decoder.convert(data, recoveringInvalidInput: true)
                            if !converted.data.isEmpty { backend.receive(converted.data) }
                            if converted.rejectedInput {
                                let message = RemoteCharsetConversionError(
                                    charset: configuration.charset, direction: .decoding
                                ).localizedDescription
                                Task { @MainActor in
                                    if reference.owner?.charsetError == nil {
                                        reference.owner?.charsetError = message
                                    }
                                }
                            }
                        } catch {
                            Task { @MainActor in
                                if reference.owner?.charsetError == nil {
                                    reference.owner?.charsetError = error.localizedDescription
                                }
                            }
                        }
                        Task { @MainActor in reference.owner?.hasUnreadOutput = true }
                    },
                    disconnected: { message in
                        Task { @MainActor in reference.owner?.fail(message) }
                    },
                    progress: { stage in
                        Task { @MainActor in
                            reference.owner?.connectionJourney.log(
                                endpoint: reference.owner?.title ?? configuration.devicePath,
                                message: stage.message
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                guard let self else {
                    await opened.close()
                    return
                }
                self.connection = opened
                self.status = .connected
                self.connectionJourney.succeed()
            } catch is CancellationError {
                self?.status = .disconnected
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        startsOnMount = false
        connectionTask?.cancel()
        connectionTask = nil
        let connection = connection
        self.connection = nil
        finishCharsetOutput()
        if let connection { Task { await connection.close() } }
        status = .disconnected
        connectionController.disconnect()
    }

    private func fail(_ message: String) {
        guard status != .disconnected else { return }
        let connection = connection
        self.connection = nil
        finishCharsetOutput()
        if let connection { Task { await connection.close() } }
        status = .failed(message)
        connectionJourney.fail(message)
        terminalBackend.receive(
            Data("\r\n\u{001B}[2m[Termind] \(message)\u{001B}[0m\r\n".utf8)
        )
    }

    func handleTerminalWrite(_ data: Data, interactive: Bool) {
        guard let connection else { return }
        let source = interactive ? configuration.transformInteractiveInput(data) : data
        let output: Data
        do {
            output = try inputConverter.convert(source).data
        } catch {
            if charsetError == nil { charsetError = error.localizedDescription }
            return
        }
        if interactive, configuration.localEcho { terminalBackend.receive(source) }
        Task {
            do { try await connection.write(output) } catch {
                await MainActor.run { self.fail(error.localizedDescription) }
            }
        }
    }

    private func finishCharsetOutput() {
        do {
            let converted = try outputConverter.finish(recoveringInvalidInput: true)
            if !converted.data.isEmpty { terminalBackend.receive(converted.data) }
            if converted.rejectedInput, charsetError == nil {
                charsetError =
                    RemoteCharsetConversionError(
                        charset: configuration.charset, direction: .decoding
                    ).localizedDescription
            }
        } catch {
            if charsetError == nil { charsetError = error.localizedDescription }
        }
    }

    func requestTerminalFocus() {
        #if canImport(AppKit)
            terminalViewOwner.requestFocus()
        #else
            terminalState.requestFocus()
        #endif
    }

    private func performFind(_ action: String) {
        #if canImport(AppKit)
            terminalViewOwner.performBindingAction(action)
        #endif
    }

}

struct SerialTerminalView: View {
    let session: SerialSessionModel
    let isVisible: Bool
    let requestsFocus: Bool
    let closePane: () -> Void

    @TerminalAppearanceSettings private var terminalAppearance
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool

    var body: some View {
        PersistentTerminalSurfaceView(
            state: session.terminalState,
            owner: session.terminalViewOwner,
            isVisible: isVisible,
            requestsFocus: requestsFocus && !session.connectionJourney.isPresented
        )
        .background(terminalAppearance.background)
        .overlay { connectionJourney }
        .focused($focused)
        .onAppear {
            TerminalFontCatalog.shared.refresh()
            session.terminalState.applyPreferences(terminalAppearance.preferences, font: terminalAppearance.font)
            session.connectIfNeeded()
            if requestsFocus { session.requestTerminalFocus() }
        }
        .onChange(of: requestsFocus) { _, value in
            focused = value
            if value, !session.connectionJourney.isPresented { session.requestTerminalFocus() }
        }
        .onChange(of: session.connectionJourney.isPresented) { _, presented in
            if !presented, requestsFocus { session.requestTerminalFocus() }
        }
        .onChange(of: terminalAppearance) { _, appearance in
            session.terminalState.applyPreferences(appearance.preferences, font: appearance.font)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { TerminalFontCatalog.shared.refresh() }
        }
        .alert("Charset Error", isPresented: charsetErrorPresented) {
            Button("OK", role: .cancel) { session.charsetError = nil }
        } message: {
            Text(session.charsetError ?? "")
        }
    }

    private var charsetErrorPresented: Binding<Bool> {
        Binding(
            get: { session.charsetError != nil },
            set: { if !$0 { session.charsetError = nil } }
        )
    }

    @ViewBuilder
    private var connectionJourney: some View {
        if isVisible, session.connectionJourney.isPresented {
            ConnectionJourneyView(
                journey: session.connectionJourney,
                submitAuthentication: { _, _, _, _, _, _ in },
                continueHostKey: { _ in },
                trustHostKey: { _ in },
                denyHostKey: closePane,
                retry: session.connect,
                cancel: closePane,
                failureCancelLabel: "Close",
                failureRetryLabel: "Reconnect",
                compactFailureActions: true
            )
        }
    }
}
