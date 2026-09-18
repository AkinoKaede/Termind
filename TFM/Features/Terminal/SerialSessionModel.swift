import Combine
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain

@MainActor
private final class SerialSessionRelay {
    weak var owner: SerialSessionModel?
    let inputCapture = TerminalInteractiveInputCapture()
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
        let relay = SerialSessionRelay()
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
        connectionTask?.cancel()
        let previousConnection = connection
        connection = nil
        status = .connecting
        connectionJourney.beginSerial(name: title, address: devicePath)
        let service = service
        let configuration = configuration
        let backend = terminalBackend
        let reference = WeakSerialSessionReference(self)
        connectionTask = Task { [weak self] in
            do {
                if let previousConnection { await previousConnection.close() }
                let opened = try await service.open(
                    configuration,
                    receive: { data in
                        backend.receive(data)
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
        if let connection { Task { await connection.close() } }
        status = .disconnected
        connectionController.disconnect()
    }

    private func fail(_ message: String) {
        guard status != .disconnected else { return }
        let connection = connection
        self.connection = nil
        if let connection { Task { await connection.close() } }
        status = .failed(message)
        connectionJourney.fail(message)
        terminalBackend.receive(
            Data("\r\n\u{001B}[2m[Termind] \(message)\u{001B}[0m\r\n".utf8)
        )
    }

    func handleTerminalWrite(_ data: Data, interactive: Bool) {
        guard let connection else { return }
        let output = interactive ? configuration.transformInteractiveInput(data) : data
        if interactive, configuration.localEcho {
            let echo = Data(data.flatMap { $0 == 0x0D ? [0x0D, 0x0A] : [$0] })
            terminalBackend.receive(echo)
        }
        Task {
            do { try await connection.write(output) } catch {
                await MainActor.run { self.fail(error.localizedDescription) }
            }
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
            session.terminalState.applyPreferences(terminalAppearance.preferences)
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
        .onChange(of: terminalAppearance.preferences) { _, value in
            session.terminalState.applyPreferences(value)
        }
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
