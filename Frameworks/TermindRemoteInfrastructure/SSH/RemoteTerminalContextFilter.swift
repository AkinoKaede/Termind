import Foundation
import TermindApplication
import TermindDomain

nonisolated struct RemoteTerminalContextFilter {
    struct Update {
        var output = Data()
        var terminal: String?
        var contexts: [TerminalRuntimeUpdate] = []
    }
    private let token: String
    private let charset: RemoteCharset
    private let prefixes: [Data]
    private var buffer = Data()

    init(token: String, charset: RemoteCharset = .utf8) {
        self.token = token
        self.charset = charset
        prefixes = [
            Data("\u{1B}]777;TermindTerminal=\(token);".utf8),
            Data("\u{1B}]777;TermindContext=\(token);".utf8),
        ]
    }

    mutating func receive(_ data: Data) -> Update {
        buffer.append(data)
        var update = Update()
        while let match = prefixes.enumerated().compactMap({ index, prefix in
            buffer.range(of: prefix).map { (index, $0) }
        }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
            update.output.append(buffer[..<match.1.lowerBound])
            guard let end = buffer[match.1.upperBound...].firstIndex(of: 7) else {
                buffer = Data(buffer[match.1.lowerBound...])
                if buffer.count > 64 * 1024 {
                    buffer.removeAll()
                    update.contexts.append(.init(status: .unavailable))
                }
                return update
            }
            let payloadBytes = Data(buffer[match.1.upperBound..<end])
            buffer = Data(buffer[buffer.index(after: end)...])
            guard payloadBytes.count <= 64 * 1024, let payload = String(data: payloadBytes, encoding: .utf8) else {
                update.contexts.append(.init(status: .unavailable))
                continue
            }
            if match.0 == 0 {
                if payload.hasPrefix("/dev/"), payload.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) {
                    update.terminal = payload
                }
            } else if let record = try? RemoteShellContextRecord(payload, charset: charset), record.token == token,
                record.pane == "shell"
            {
                var context = record.context(server: token, session: token, backend: "shell")
                if context.promptReady {
                    context.capabilities.formUnion([.readDraft, .replaceDraft])
                } else {
                    context.capabilities.remove(.directory)
                }
                update.contexts.append(
                    .init(
                        status: .ordinary, active: context.identity,
                        contexts: [context], events: record.events(for: context)))
            } else {
                update.contexts.append(.init(status: .unavailable))
            }
        }
        let maximum = min(buffer.count, prefixes.map(\.count).max()! - 1)
        var retained = 0
        if maximum > 0 {
            for count in stride(from: maximum, through: 1, by: -1) {
                if prefixes.contains(where: { buffer.suffix(count).elementsEqual($0.prefix(count)) }) {
                    retained = count
                    break
                }
            }
        }
        let end = buffer.index(buffer.endIndex, offsetBy: -retained)
        update.output.append(buffer[..<end])
        buffer = Data(buffer[end...])
        return update
    }

    static func needsObservation(_ update: TerminalRuntimeUpdate) -> Bool {
        update.status != .ordinary
            || update.contexts.first(where: { $0.identity == update.active })?.promptReady != true
    }

    static func reconcileObservation(
        _ observation: TerminalRuntimeUpdate, current: TerminalRuntimeUpdate?
    ) -> TerminalRuntimeUpdate {
        // A negative multiplexer probe does not invalidate the authenticated outer
        // shell's cwd. Keep polling for manual attach, without restoring prompt rights.
        if observation.status == .unknown || observation.status == .unavailable,
            let current, current.status == .ordinary,
            let shell = current.contexts.first(where: { $0.identity == current.active }),
            shell.identity.backend == "shell", !shell.promptReady
        {
            var retained = current
            retained.events = []
            return retained
        }
        return observation
    }
}
