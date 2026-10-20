// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
@preconcurrency import Network
import TermindApplication
import TermindDomain

public nonisolated final class TelnetConnection: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (Data) -> Void
    public typealias EventHandler = @Sendable (TelnetConnectionEvent) -> Void
    public typealias CloseHandler = @Sendable (String?) -> Void

    private let worker: TelnetConnectionWorker

    public init(
        output: @escaping OutputHandler,
        event: @escaping EventHandler = { _ in },
        closed: @escaping CloseHandler = { _ in }
    ) {
        worker = TelnetConnectionWorker(output: output, event: event, closed: closed)
    }

    public func connect(
        using configuration: TelnetConnectionConfiguration,
        columns: UInt16 = 80, rows: UInt16 = 24
    ) async throws {
        try await worker.connect(using: configuration, columns: columns, rows: rows)
    }

    public func write(_ data: Data) { worker.write(data) }

    public func resize(columns: UInt16, rows: UInt16) {
        worker.resize(columns: columns, rows: rows)
    }

    public func disconnect() { worker.disconnect() }
}

private nonisolated final class TelnetConnectionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.akinokaede.termind.telnet")
    private let output: TelnetConnection.OutputHandler
    private let event: TelnetConnection.EventHandler
    private let closed: TelnetConnection.CloseHandler

    private var connection: NWConnection?
    private var socket: Int32 = -1
    private var socketReadSource: (any DispatchSourceRead)?
    private var parser = TelnetProtocolParser()
    private var inputConverter: RemoteCharsetStreamConverter?
    private var outputConverter: RemoteCharsetStreamConverter?
    private var configuration: TelnetConnectionConfiguration?
    private var columns: UInt16 = 80
    private var rows: UInt16 = 24
    private var generation = UUID()
    private var promptTail = ""
    private var sentUsername = false
    private var sentPassword = false
    private var didBecomeReady = false
    private var didClose = false
    private var pendingConnect: CheckedContinuation<Void, any Error>?

    init(
        output: @escaping TelnetConnection.OutputHandler,
        event: @escaping TelnetConnection.EventHandler,
        closed: @escaping TelnetConnection.CloseHandler
    ) {
        self.output = output
        self.event = event
        self.closed = closed
    }

    func connect(
        using configuration: TelnetConnectionConfiguration,
        columns: UInt16, rows: UInt16
    ) async throws {
        guard (1...65_535).contains(configuration.port), !configuration.host.isEmpty,
            let port = NWEndpoint.Port(rawValue: UInt16(configuration.port))
        else {
            configuration.clearSecret()
            throw TelnetConnectionError.invalidConfiguration
        }

        do {
            try Task.checkCancellation()
            try configuration.accessCheck?()
            await configuration.beforeConnect?()
            try Task.checkCancellation()
        } catch {
            configuration.clearSecret()
            throw error
        }

        if configuration.proxy != nil {
            try await connectThroughProxy(
                using: configuration, columns: columns, rows: rows)
            return
        }

        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    generation = token
                    cleanup(notify: false)
                    didClose = false
                    pendingConnect = continuation
                    self.configuration = configuration
                    self.columns = max(columns, 1)
                    self.rows = max(rows, 1)
                    do {
                        event(.configuringCharset)
                        inputConverter = try RemoteCharsetStreamConverter(
                            charset: configuration.charset, direction: .encoding)
                        outputConverter = try RemoteCharsetStreamConverter(
                            charset: configuration.charset, direction: .decoding)
                    } catch {
                        configuration.clearSecret()
                        resumeConnect(.failure(error))
                        return
                    }

                    event(.openingTransport)
                    let connection = NWConnection(
                        host: NWEndpoint.Host(configuration.host), port: port, using: .tcp)
                    self.connection = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        self.queue.async {
                            guard self.generation == token else { return }
                            switch state {
                            case .ready:
                                self.resumeConnect(.success(()))
                                self.didOpen(token: token)
                            case .failed(let error):
                                self.resumeConnect(.failure(error))
                                self.finish(message: error.localizedDescription)
                            case .cancelled:
                                self.resumeConnect(.failure(CancellationError()))
                            default:
                                break
                            }
                        }
                    }
                    connection.start(queue: queue)
                }
            }
        } onCancel: {
            self.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.resumeConnect(.failure(CancellationError()))
                self.cleanup(notify: false)
            }
        }
    }

    private func connectThroughProxy(
        using configuration: TelnetConnectionConfiguration,
        columns: UInt16, rows: UInt16
    ) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    generation = token
                    cleanup(notify: false)
                    didClose = false
                    pendingConnect = continuation
                    self.configuration = configuration
                    self.columns = max(columns, 1)
                    self.rows = max(rows, 1)
                    do {
                        event(.configuringCharset)
                        inputConverter = try RemoteCharsetStreamConverter(
                            charset: configuration.charset, direction: .encoding)
                        outputConverter = try RemoteCharsetStreamConverter(
                            charset: configuration.charset, direction: .decoding)
                    } catch {
                        configuration.clearSecret()
                        resumeConnect(.failure(error))
                        return
                    }
                    event(.openingTransport)
                    let opening = Task.detached {
                        Result {
                            try TerminalSocketConnector.open(
                                host: configuration.host, port: configuration.port,
                                proxy: configuration.proxy, timeout: 20)
                        }
                    }
                    Task {
                        let result = await opening.value
                        self.queue.async {
                            guard self.generation == token else {
                                if case .success(let opened) = result { Darwin.close(opened) }
                                return
                            }
                            switch result {
                            case .success(let opened):
                                self.socket = opened
                                self.installSocketReader(token: token)
                                self.resumeConnect(.success(()))
                                self.didOpen(token: token)
                            case .failure(let error):
                                self.resumeConnect(.failure(error))
                                self.finish(message: error.localizedDescription)
                            }
                        }
                    }
                }
            }
        } onCancel: {
            self.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.resumeConnect(.failure(CancellationError()))
                self.cleanup(notify: false)
            }
        }
    }

    private func installSocketReader(token: UUID) {
        guard socket >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.generation == token, self.socket >= 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(self.socket, &bytes, bytes.count)
            if count > 0 {
                self.receiveWire(Data(bytes.prefix(count)))
            } else if count == 0 {
                self.finish(message: nil)
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                self.finish(message: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)
            }
        }
        source.setCancelHandler {}
        source.resume()
        socketReadSource = source
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard connection != nil else { return }
            let encoded = (try? inputConverter?.convert(data).data) ?? data
            sendApplicationData(encoded)
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        guard columns > 0, rows > 0 else { return }
        queue.async { [self] in
            self.columns = columns
            self.rows = rows
            guard parser.nawsEnabled else { return }
            sendProtocol(parser.windowSize(columns: columns, rows: rows))
        }
    }

    func disconnect() {
        queue.async { [self] in cleanup(notify: false) }
    }

    private func didOpen(token: UUID) {
        guard generation == token, connection != nil else { return }
        event(.negotiatingOptions)
        sendProtocol(parser.initialNegotiation)
        receive(token: token)
        if configuration?.username?.isEmpty == false {
            event(.waitingForUsernamePrompt)
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.generation == token, !self.didBecomeReady else { return }
                self.configuration?.clearSecret()
                self.event(.continuingManually)
                self.markReady()
            }
        } else {
            markReady()
        }
    }

    private func receive(token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard self.generation == token else { return }
                if let data, !data.isEmpty { self.receiveWire(data) }
                if let error {
                    self.finish(message: error.localizedDescription)
                } else if complete {
                    self.finish(message: nil)
                } else {
                    self.receive(token: token)
                }
            }
        }
    }

    private func receiveWire(_ data: Data) {
        let result = parser.consume(data)
        if !result.reply.isEmpty { sendProtocol(result.reply) }
        if result.enabledNAWS {
            sendProtocol(parser.windowSize(columns: columns, rows: rows))
        }
        guard !result.applicationData.isEmpty else { return }
        do {
            let converted =
                try outputConverter?.convert(result.applicationData)
                ?? .init(data: result.applicationData, rejectedInput: false)
            guard !converted.data.isEmpty else { return }
            output(converted.data)
            inspectPrompts(in: converted.data)
        } catch {
            output(result.applicationData)
            inspectPrompts(in: result.applicationData)
        }
    }

    private func inspectPrompts(in data: Data) {
        promptTail.append(String(decoding: data, as: UTF8.self).lowercased())
        if promptTail.count > 512 { promptTail = String(promptTail.suffix(512)) }
        let trimmed = promptTail.trimmingCharacters(in: .whitespacesAndNewlines)

        if !sentUsername, let username = configuration?.username,
            ["login:", "username:", "user name:"].contains(where: trimmed.hasSuffix)
        {
            do {
                try sendAutomatedText(username)
                sentUsername = true
                promptTail = ""
                event(.usernameSubmitted)
                if configuration?.password != nil {
                    event(.waitingForPasswordPrompt)
                } else {
                    event(.continuingManually)
                    markReady()
                }
            } catch {
                failAutomaticLogin(error)
            }
            return
        }

        guard trimmed.hasSuffix("password:") else { return }
        guard !sentPassword else {
            configuration?.clearSecret()
            event(.continuingManually)
            markReady()
            return
        }
        guard let secret = configuration?.password else {
            markReady()
            return
        }
        do {
            try sendAutomatedSecret(secret)
            sentPassword = true
            promptTail = ""
            event(.passwordSubmitted)
            markReady()
        } catch {
            failAutomaticLogin(error)
        }
    }

    private func sendAutomatedText(_ value: String) throws {
        guard let inputConverter else { throw TelnetConnectionError.closed }
        var utf8 = Data(value.utf8)
        defer { SecretMemory.clear(&utf8) }
        let encoded = try inputConverter.convert(utf8).data
        sendApplicationLine(encoded)
    }

    private func sendAutomatedSecret(_ secret: SSHSecret) throws {
        guard let inputConverter else { throw TelnetConnectionError.closed }
        var utf8 = try secret.withUnsafeCStringAndConsume { pointer, count in
            Data(bytes: pointer, count: count)
        }
        defer { SecretMemory.clear(&utf8) }
        var encoded = try inputConverter.convert(utf8).data
        defer { SecretMemory.clear(&encoded) }
        sendApplicationLine(encoded)
    }

    private func failAutomaticLogin(_: any Error) {
        configuration?.clearSecret()
        event(.continuingManually)
        markReady()
    }

    private func markReady() {
        guard !didBecomeReady else { return }
        didBecomeReady = true
        event(.connected)
    }

    private func sendApplicationLine(_ data: Data) {
        var line = data
        line.append(contentsOf: [0x0D, 0x0A])
        sendApplicationData(line)
    }

    private func sendApplicationData(_ data: Data) {
        sendWire(TelnetProtocolParser.escapeApplicationData(TelnetProtocolParser.encodeNVT(data)))
    }

    private func sendProtocol(_ data: Data) { sendWire(data) }

    private func sendWire(_ data: Data) {
        guard !data.isEmpty else { return }
        if socket >= 0 {
            do {
                try data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var offset = 0
                    while offset < raw.count {
                        let count = Darwin.write(socket, base.advanced(by: offset), raw.count - offset)
                        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        offset += count
                    }
                }
            } catch {
                finish(message: error.localizedDescription)
            }
            return
        }
        guard let connection else { return }
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                let message = error.localizedDescription
                self.queue.async { [weak self] in self?.finish(message: message) }
            })
    }

    private func finish(message: String?) {
        guard !didClose else { return }
        didClose = true
        cleanup(notify: false)
        closed(message)
    }

    private func resumeConnect(_ result: Result<Void, any Error>) {
        guard let continuation = pendingConnect else { return }
        pendingConnect = nil
        continuation.resume(with: result)
    }

    private func cleanup(notify: Bool) {
        if let outputConverter {
            do {
                let tail = try outputConverter.finish()
                if !tail.data.isEmpty { output(tail.data) }
            } catch {}
        }
        configuration?.clearSecret()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        socketReadSource?.cancel()
        socketReadSource = nil
        if socket >= 0 { Darwin.close(socket) }
        socket = -1
        configuration = nil
        inputConverter = nil
        outputConverter = nil
        parser = TelnetProtocolParser()
        promptTail = ""
        sentUsername = false
        sentPassword = false
        didBecomeReady = false
        if notify, !didClose { closed(nil) }
    }
}

nonisolated struct TelnetProtocolParser {
    private enum State {
        case data
        case iac
        case optionCommand(UInt8)
        case subOption
        case subData
        case subIAC
    }

    struct Result {
        var applicationData = Data()
        var reply = Data()
        var enabledNAWS = false
    }

    private static let iac: UInt8 = 255
    private static let dont: UInt8 = 254
    private static let `do`: UInt8 = 253
    private static let wont: UInt8 = 252
    private static let will: UInt8 = 251
    private static let sb: UInt8 = 250
    private static let se: UInt8 = 240
    private static let binary: UInt8 = 0
    private static let echo: UInt8 = 1
    private static let suppressGoAhead: UInt8 = 3
    private static let terminalType: UInt8 = 24
    private static let windowSize: UInt8 = 31

    private var state: State = .data
    private var subOption: UInt8?
    private var subData = Data()
    private var pendingCR = false
    private(set) var nawsEnabled = false

    var initialNegotiation: Data {
        Data([
            Self.iac, Self.will, Self.terminalType,
            Self.iac, Self.will, Self.windowSize,
            Self.iac, Self.will, Self.binary,
            Self.iac, Self.do, Self.binary,
            Self.iac, Self.do, Self.suppressGoAhead,
            Self.iac, Self.do, Self.echo,
        ])
    }

    mutating func consume(_ data: Data) -> Result {
        var result = Result()
        for byte in data {
            switch state {
            case .data:
                if byte == Self.iac {
                    state = .iac
                } else {
                    appendNVT(byte, to: &result.applicationData)
                }
            case .iac:
                switch byte {
                case Self.iac:
                    appendNVT(byte, to: &result.applicationData)
                    state = .data
                case Self.do, Self.dont, Self.will, Self.wont:
                    state = .optionCommand(byte)
                case Self.sb:
                    state = .subOption
                default:
                    state = .data
                }
            case .optionCommand(let command):
                let reply = negotiate(command: command, option: byte)
                result.reply.append(reply.data)
                result.enabledNAWS = reply.enabledNAWS
                state = .data
            case .subOption:
                subOption = byte
                subData.removeAll(keepingCapacity: true)
                state = .subData
            case .subData:
                if byte == Self.iac { state = .subIAC } else { subData.append(byte) }
            case .subIAC:
                if byte == Self.se {
                    result.reply.append(subnegotiationReply())
                    subOption = nil
                    subData.removeAll(keepingCapacity: true)
                    state = .data
                } else if byte == Self.iac {
                    subData.append(byte)
                    state = .subData
                } else {
                    state = .subData
                }
            }
        }
        return result
    }

    mutating func windowSize(columns: UInt16, rows: UInt16) -> Data {
        var payload = Data([
            UInt8(columns >> 8), UInt8(columns & 0xFF),
            UInt8(rows >> 8), UInt8(rows & 0xFF),
        ])
        payload = Self.escapeApplicationData(payload)
        return Data([Self.iac, Self.sb, Self.windowSize]) + payload + Data([Self.iac, Self.se])
    }

    static func escapeApplicationData(_ data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count + 8)
        for byte in data {
            if byte == iac { result.append(iac) }
            result.append(byte)
        }
        return result
    }

    static func encodeNVT(_ data: Data) -> Data {
        let bytes = Array(data)
        var result = Data()
        result.reserveCapacity(bytes.count + 8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D {
                result.append(0x0D)
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    result.append(0x0A)
                    index += 2
                    continue
                }
                result.append(0x0A)
            } else if byte == 0x0A {
                result.append(contentsOf: [0x0D, 0x0A])
            } else {
                result.append(byte)
            }
            index += 1
        }
        return result
    }

    private mutating func appendNVT(_ byte: UInt8, to output: inout Data) {
        if pendingCR {
            pendingCR = false
            if byte == 0 {
                output.append(0x0D)
                return
            }
            output.append(0x0D)
        }
        if byte == 0x0D { pendingCR = true } else { output.append(byte) }
    }

    private mutating func negotiate(command: UInt8, option: UInt8) -> (data: Data, enabledNAWS: Bool) {
        var enabledNAWS = false
        let response: UInt8
        switch command {
        case Self.will:
            response = [Self.binary, Self.echo, Self.suppressGoAhead].contains(option) ? Self.do : Self.dont
        case Self.do:
            let supported = [Self.binary, Self.suppressGoAhead, Self.terminalType, Self.windowSize].contains(option)
            response = supported ? Self.will : Self.wont
            if option == Self.windowSize, supported, !nawsEnabled {
                nawsEnabled = true
                enabledNAWS = true
            }
        case Self.wont:
            response = Self.dont
        default:
            response = Self.wont
        }
        return (Data([Self.iac, response, option]), enabledNAWS)
    }

    private func subnegotiationReply() -> Data {
        guard subOption == Self.terminalType, subData.first == 1 else { return Data() }
        return Data([Self.iac, Self.sb, Self.terminalType, 0])
            + Data("xterm-256color".utf8)
            + Data([Self.iac, Self.se])
    }
}
