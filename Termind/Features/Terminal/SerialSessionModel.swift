import Combine
import GhosttyTerminal
import SwiftUI

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
    private(set) var findQuery = ""
    private(set) var isFindPresented = false

    let terminalState: TerminalViewState
    #if canImport(AppKit)
        let terminalViewOwner: PersistentTerminalViewOwner
    #endif
    private let terminalBackend: InMemoryTerminalSession
    private let service: any SerialPortServing
    private var connection: (any SerialPortConnection)?
    private var connectionTask: Task<Void, Never>?
    let connectionController = RemoteSessionConnectionController()
    var connectionJourney: SSHConnectionJourney { connectionController.journey }

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
                let interactive = relay.inputCapture.classifyWrite()
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

    func connect() {
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
                guard let self else { await opened.close(); return }
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
            do { try await connection.write(output) }
            catch { await MainActor.run { self.fail(error.localizedDescription) } }
        }
    }

    func requestTerminalFocus() {
        #if canImport(AppKit)
            terminalViewOwner.requestFocus()
        #else
            terminalState.requestFocus()
        #endif
    }

    func presentFind() {
        let wasPresented = isFindPresented
        isFindPresented = true
        if !wasPresented, !findQuery.isEmpty { performFind(TerminalFindBinding.search(findQuery)) }
    }
    func updateFindQuery(_ query: String) {
        guard query != findQuery else { return }
        findQuery = query
        performFind(TerminalFindBinding.search(query))
    }
    func presentFindAndNavigate(_ direction: TerminalFindDirection) {
        presentFind()
        guard !findQuery.isEmpty else { return }
        performFind(TerminalFindBinding.navigate(direction))
    }
    func dismissFind() {
        guard isFindPresented else { return }
        performFind(TerminalFindBinding.end)
        isFindPresented = false
        requestTerminalFocus()
    }
    private func performFind(_ action: String) {
        #if canImport(AppKit)
            terminalViewOwner.performBindingAction(action)
        #endif
    }

    func applyAppearance(_ preferences: TerminalAppearancePreferences) {
        let light = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: preferences.lightThemeName,
            customEnabled: preferences.lightCustomEnabled,
            customText: preferences.lightCustomConfiguration,
            isDark: false
        )
        let dark = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: preferences.darkThemeName,
            customEnabled: preferences.darkCustomEnabled,
            customText: preferences.darkCustomConfiguration,
            isDark: true
        )
        terminalState.setTheme(GhosttyTerminal.TerminalTheme(light: light, dark: dark))
        terminalState.setTerminalConfiguration(
            TerminalConfiguration { builder in
                if !preferences.fontFollowTheme { builder.withFontSize(Float(preferences.fontSize)) }
                builder.withWindowPaddingX(Int(Metrics.Space.m))
                builder.withWindowPaddingY(Int(Metrics.Space.m))
            }
        )
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
            session.terminalState.isSurfaceVisible = isVisible
            session.applyAppearance(terminalAppearance.preferences)
            if session.status == .connecting { session.connect() }
            if requestsFocus { session.requestTerminalFocus() }
        }
        .onChange(of: isVisible) { _, value in session.terminalState.isSurfaceVisible = value }
        .onChange(of: requestsFocus) { _, value in
            focused = value
            if value, !session.connectionJourney.isPresented { session.requestTerminalFocus() }
        }
        .onChange(of: session.connectionJourney.isPresented) { _, presented in
            if !presented, requestsFocus { session.requestTerminalFocus() }
        }
        .onChange(of: terminalAppearance.preferences) { _, value in session.applyAppearance(value) }
        .onDisappear { session.terminalState.isSurfaceVisible = false }
    }

    @ViewBuilder
    private var connectionJourney: some View {
        if isVisible, session.connectionJourney.isPresented {
            SSHConnectionJourneyView(
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
