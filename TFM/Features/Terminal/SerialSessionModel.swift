// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Combine
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

@MainActor
private final class SerialSessionRelay {
    weak var owner: SerialSessionModel?
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
    var status: ConnectionStatus = .disconnected {
        didSet { if !status.isLive, status != .connecting { commandMonitor.endConnection() } }
    }
    let commandMonitor = TerminalCommandMonitor()
    private var commandObservation: TerminalCommandObservation?
    var hasUnreadOutput = false
    @ObservationIgnored lazy var find = TerminalFindController(
        perform: { [weak self] in self?.performFind($0) },
        focus: { [weak self] in self?.requestTerminalFocus() }
    )

    private let terminalSurface: PersistentTerminalViewOwner
    var terminalState: TerminalViewState { terminalSurface.state }
    var terminalViewOwner: PersistentTerminalViewOwner { terminalSurface }
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
        terminalSurface = PersistentTerminalViewOwner(
            write: { data, interactive in
                Task { @MainActor in relay.owner?.handleTerminalWrite(data, interactive: interactive) }
            },
            resize: { _ in }
        )
        relay.owner = self
        commandObservation = TerminalCommandObservation(state: terminalSurface.state, monitor: commandMonitor)
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
        commandMonitor.beginConnection()
        connectionJourney.beginSerial(name: title, address: devicePath)
        let service = service
        let configuration = configuration
        let terminalSurface = terminalSurface
        let decoder = outputConverter
        let reference = WeakSerialSessionReference(self)
        connectionTask = Task { [weak self] in
            do {
                if let previousConnection { await previousConnection.close() }
                let opened = try await service.open(
                    configuration,
                    receive: { data in
                        do {
                            let converted = try decoder.convert(data)
                            if !converted.data.isEmpty { terminalSurface.receive(converted.data) }
                        } catch {
                            terminalSurface.receive(data)
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
        terminalSurface.appendNotice(message)
    }

    func handleTerminalWrite(_ data: Data, interactive: Bool) {
        guard let connection else { return }
        let source = interactive ? configuration.transformInteractiveInput(data) : data
        let output = (try? inputConverter.convert(source).data) ?? source
        if interactive, configuration.localEcho { terminalSurface.receive(source) }
        Task {
            do { try await connection.write(output) } catch {
                await MainActor.run { self.fail(error.localizedDescription) }
            }
        }
    }

    private func finishCharsetOutput() {
        do {
            let converted = try outputConverter.finish()
            if !converted.data.isEmpty { terminalSurface.receive(converted.data) }
        } catch {}
    }

    func requestTerminalFocus() {
        terminalSurface.requestFocus()
    }

    private func performFind(_ action: String) {
        terminalSurface.performBindingAction(action)
    }

}

struct SerialTerminalView: View {
    let session: SerialSessionModel
    let isVisible: Bool
    let requestsFocus: Bool
    let closePane: () -> Void

    var body: some View {
        SimpleDesktopTerminalView(
            state: session.terminalState,
            owner: session.terminalViewOwner,
            journey: session.connectionJourney,
            isVisible: isVisible,
            requestsFocus: requestsFocus,
            connectIfNeeded: session.connectIfNeeded,
            retry: session.connect,
            requestFocus: session.requestTerminalFocus,
            closePane: closePane
        )
    }

}
