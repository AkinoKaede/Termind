import CSSH2
import Darwin
import Foundation
import TermindApplication

/// The C callback cannot suspend. Only its dedicated transport queue waits on
/// this condition; the responder runs asynchronously and cancellation wakes it.
public nonisolated final class SSHKeyboardInteractiveExchange: @unchecked Sendable {
    private let condition = NSCondition()
    private let handler: SSHKeyboardInteractiveHandler?
    private var cancelled = false
    private var task: Task<Void, Never>?
    private var result: Result<[String], any Error>?
    private var requestID: UUID?
    private(set) var error: (any Error)?
    private var connectionID = UUID()
    private var round = 0
    private var hostID: UUID
    private var hostname: String
    private var port: Int
    private var username: String

    init(configuration: SSHConnectionConfiguration, handler: SSHKeyboardInteractiveHandler?) {
        self.handler = handler
        hostID = configuration.hostID
        hostname = configuration.host
        port = configuration.port
        username = configuration.username
    }

    func setHop(_ hop: SSHRouteHopConfiguration) {
        connectionID = UUID()
        hostID = hop.id
        hostname = hop.host
        port = hop.port
        username = hop.username
        round = 0
    }

    func cancel() {
        condition.lock()
        cancelled = true
        let pending = task
        result = .failure(CancellationError())
        condition.broadcast()
        condition.unlock()
        pending?.cancel()
    }

    func checkCancellation() throws {
        condition.lock()
        let stopped = cancelled
        condition.unlock()
        if stopped { throw CancellationError() }
    }

    func answer(name: String, instruction: String, prompts: [SSHKeyboardInteractiveChallenge.Prompt]) throws -> [String]
    {
        try checkCancellation()
        guard let handler else {
            throw TermindSSHError.authenticationFailed(
                String(localized: "This server requires interactive authentication.")
            )
        }
        round += 1
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: connectionID, hostID: hostID, hostname: hostname, port: port,
            username: username, round: round, name: name, instruction: instruction, prompts: prompts
        )
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            throw CancellationError()
        }
        result = nil
        requestID = challenge.id
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<[String], any Error>
            do {
                let answers = try await handler(challenge)
                guard answers.count == prompts.count else {
                    throw TermindSSHError.library(String(localized: "Invalid authentication response."))
                }
                result = .success(answers)
            } catch { result = .failure(error) }
            self?.finish(challenge.id, result: result)
        }
        while result == nil { condition.wait() }
        let answer = result!
        result = nil
        task = nil
        requestID = nil
        condition.unlock()
        return try answer.get()
    }

    private func finish(_ id: UUID, result: Result<[String], any Error>) {
        condition.lock()
        if requestID == id, !cancelled {
            self.result = result
            condition.broadcast()
        }
        condition.unlock()
    }

    func recordFailure(_ failure: any Error) { error = failure }
}

nonisolated func sshKeyboardInteractiveResponse(
    _ name: UnsafePointer<CChar>?, _ nameLength: Int32,
    _ instruction: UnsafePointer<CChar>?, _ instructionLength: Int32,
    _ promptCount: Int32,
    _ prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    _ responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) {
    guard let opaque = abstract?.pointee else { return }
    let callback = Unmanaged<SSHKeyboardInteractiveCallback>.fromOpaque(opaque).takeUnretainedValue()
    callback.respond(
        name: name, nameLength: nameLength, instruction: instruction, instructionLength: instructionLength,
        count: promptCount, prompts: prompts, responses: responses
    )
}

nonisolated final class SSHKeyboardInteractiveCallback {
    let exchange: SSHKeyboardInteractiveExchange
    let session: OpaquePointer
    let socket: Int32

    init(exchange: SSHKeyboardInteractiveExchange, session: OpaquePointer, socket: Int32) {
        self.exchange = exchange
        self.session = session
        self.socket = socket
    }

    private func string(_ pointer: UnsafePointer<CChar>?, length: Int) -> String {
        guard let pointer, length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    func respond(
        name: UnsafePointer<CChar>?, nameLength: Int32,
        instruction: UnsafePointer<CChar>?, instructionLength: Int32,
        count: Int32, prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
        responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?
    ) {
        let started = ContinuousClock.now
        defer {
            // libssh2's blocking wrapper measures elapsed time across callbacks.
            // Extend this call's budget by the time spent waiting for the user.
            let elapsed = started.duration(to: .now).components
            let timeout = libssh2_session_get_timeout(session)
            if timeout > 0 {
                libssh2_session_set_timeout(
                    session, timeout + Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
                )
            }
        }
        do {
            guard count >= 0, count == 0 || (prompts != nil && responses != nil) else {
                throw TermindSSHError.library(String(localized: "Invalid authentication challenge."))
            }
            let questions = (0..<Int(count)).map { index in
                let prompt = prompts![index]
                return SSHKeyboardInteractiveChallenge.Prompt(
                    text: string(
                        prompt.text.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                        length: Int(prompt.length)), echo: prompt.echo != 0
                )
            }
            let answers = try exchange.answer(
                name: string(name, length: Int(nameLength)),
                instruction: string(instruction, length: Int(instructionLength)), prompts: questions
            )
            for (index, answer) in answers.enumerated() {
                let bytes = Array(answer.utf8)
                guard bytes.count <= Int(UInt32.max), let buffer = malloc(bytes.count + 1) else {
                    throw TermindSSHError.library(String(localized: "Invalid authentication response."))
                }
                bytes.withUnsafeBytes { source in
                    if let base = source.baseAddress { buffer.copyMemory(from: base, byteCount: bytes.count) }
                }
                buffer.storeBytes(of: UInt8(0), toByteOffset: bytes.count, as: UInt8.self)
                responses![index].text = buffer.assumingMemoryBound(to: CChar.self)
                responses![index].length = UInt32(bytes.count)
            }
        } catch {
            exchange.recordFailure(error)
            // The callback has no error return. Stop the transport before
            // libssh2 can submit empty responses or await another server packet.
            if socket >= 0 { _ = Darwin.shutdown(socket, SHUT_RDWR) }
        }
    }
}
