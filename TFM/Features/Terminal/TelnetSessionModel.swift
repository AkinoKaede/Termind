import Combine
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

@MainActor
private final class TelnetSessionRelay {
    weak var owner: TelnetSessionModel?
}

@Observable
final class TelnetSessionModel: Identifiable {
    let id = UUID()
    let hostID: Host.ID
    var title: String
    var status: ConnectionStatus = .disconnected {
        didSet { statusStore?.setConnectionStatus(status, connectionID: id, hostID: hostID) }
    }
    var hasUnreadOutput = false
    var charsetError: String?
    @ObservationIgnored lazy var find = TerminalFindController(
        perform: { [weak self] in self?.performFind($0) },
        focus: { [weak self] in self?.requestTerminalFocus() }
    )

    private let terminalSurface: PersistentTerminalViewOwner
    var terminalState: TerminalViewState { terminalSurface.state }
    var terminalViewOwner: PersistentTerminalViewOwner { terminalSurface }
    private weak var statusStore: (any RemoteSessionHostStore)?
    private let transientHost: Host
    private var connection: TelnetConnection?
    private var connectionTask: Task<Void, Never>?
    private var startsOnMount = true
    private var latestViewport = InMemoryTerminalViewport(columns: 80, rows: 24)
    let connectionController = RemoteSessionConnectionController()
    var connectionJourney: ConnectionJourney { connectionController.journey }

    var agentTemporaryTarget: AgentHostTarget? {
        guard statusStore?.host(hostID) == nil else { return nil }
        let state: String
        switch status {
        case .disconnected: state = "disconnected"
        case .connecting: state = "connecting"
        case .connected: state = "connected"
        case .reconnecting: state = "reconnecting"
        case .failed: state = "failed"
        }
        let address = transientHost.displayAddress(for: .telnet)
        return AgentHostTarget(
            id: hostID, displayName: title, address: address,
            tags: transientHost.tags, connectionState: state, isTemporary: true,
            preferredTerminalProtocol: .telnet,
            protocols: [.init(name: .telnet, address: address, connectionState: state)])
    }

    init(host: Host) {
        hostID = host.id
        title = host.name
        transientHost = host
        let relay = TelnetSessionRelay()
        terminalSurface = PersistentTerminalViewOwner(
            write: { data, _ in
                Task { @MainActor in relay.owner?.connection?.write(data) }
            },
            resize: { viewport in
                Task { @MainActor in
                    relay.owner?.latestViewport = viewport
                    relay.owner?.connection?.resize(
                        columns: UInt16(clamping: viewport.columns),
                        rows: UInt16(clamping: viewport.rows))
                }
            }
        )
        relay.owner = self
        connectionJourney.beginTelnet(
            host: host, username: nil, mode: .connection)
    }

    func copyForReconnect() -> TelnetSessionModel? {
        TelnetSessionModel(host: statusStore?.host(hostID) ?? transientHost)
    }

    func prepareForReopen() {
        startsOnMount = true
        status = .connecting
    }

    func connectIfNeeded(using store: any RemoteSessionHostStore) {
        guard startsOnMount, status == .connecting else { return }
        connect(using: store)
    }

    func connect(using store: any RemoteSessionHostStore) {
        startsOnMount = false
        statusStore = store
        charsetError = nil
        connectionTask?.cancel()
        connection?.disconnect()
        connection = nil
        let host = store.host(hostID) ?? transientHost
        guard host.telnetEnabled else {
            fail(String(localized: "Telnet is disabled for this Host."))
            return
        }
        let username = store.identity(for: host, protocol: .telnet)?.username
        connectionJourney.beginTelnet(
            host: host, username: username,
            mode: connectionController.hasConnectedOnce ? .reconnection : .connection)
        status = connectionController.hasConnectedOnce ? .reconnecting : .connecting

        let terminalSurface = terminalSurface
        let token = UUID()
        let connection = TelnetConnection(
            output: { [weak self] data in
                terminalSurface.receive(data)
                Task { @MainActor in self?.hasUnreadOutput = true }
            },
            event: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.connection != nil else { return }
                    self.connectionJourney.receive(event)
                    if case .connected = event {
                        _ = self.connectionController.markConnected()
                        self.status = .connected
                        self.connectionJourney.succeed()
                    }
                }
            },
            charsetError: { [weak self] message in
                Task { @MainActor in
                    if self?.charsetError == nil { self?.charsetError = message }
                }
            },
            closed: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.connection != nil else { return }
                    self.connection = nil
                    self.fail(message ?? String(localized: "The Telnet connection closed."))
                }
            }
        )
        self.connection = connection
        let viewport = latestViewport
        connectionTask = Task { [weak self] in
            do {
                let configuration = try store.telnetConnectionConfiguration(for: host)
                try await connection.connect(
                    using: configuration,
                    columns: UInt16(clamping: viewport.columns),
                    rows: UInt16(clamping: viewport.rows))
            } catch is CancellationError {
                await MainActor.run { self?.status = .disconnected }
            } catch {
                await MainActor.run {
                    guard self?.connection != nil else { return }
                    self?.connection = nil
                    self?.fail(error.localizedDescription)
                }
            }
            _ = token
        }
    }

    func disconnect() {
        startsOnMount = false
        connectionTask?.cancel()
        connectionTask = nil
        connection?.disconnect()
        connection = nil
        status = .disconnected
        connectionController.disconnect()
    }

    func insert(_ text: String, submit: Bool = false) {
        connection?.write(Data((text + (submit ? "\r" : "")).utf8))
    }

    private func fail(_ message: String) {
        guard status != .disconnected else { return }
        connection?.disconnect()
        connection = nil
        status = .failed(message)
        connectionJourney.fail(message)
        terminalSurface.appendNotice(message)
    }

    func requestTerminalFocus() { terminalSurface.requestFocus() }
    private func performFind(_ action: String) { terminalSurface.performBindingAction(action) }
}

struct TelnetTerminalView: View {
    let session: TelnetSessionModel
    let isVisible: Bool
    let requestsFocus: Bool
    let closePane: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        SimpleDesktopTerminalView(
            state: session.terminalState,
            owner: session.terminalViewOwner,
            journey: session.connectionJourney,
            isVisible: isVisible,
            requestsFocus: requestsFocus,
            charsetError: charsetError,
            connectIfNeeded: { session.connectIfNeeded(using: app.hostLibrary) },
            retry: { session.connect(using: app.hostLibrary) },
            requestFocus: session.requestTerminalFocus,
            closePane: closePane
        )
    }

    private var charsetError: Binding<String?> {
        Binding(
            get: { session.charsetError },
            set: { session.charsetError = $0 }
        )
    }

}
