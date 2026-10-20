// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum TerminalDraftError: LocalizedError, Sendable {
    case unavailable
    case alreadyPending
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized:
                    "Command Generator requires a supported shell prompt with Shell Integration enabled."
            )
        case .alreadyPending:
            String(localized: "Command Generator is already reading the current input.")
        case .timedOut:
            String(localized: "The remote shell did not return its current input.")
        }
    }
}

@MainActor
public final class TerminalCommandDraftController {
    public typealias Write = @MainActor @Sendable (Data) async -> Void

    private struct Request {
        var id: UUID
        var continuation: CheckedContinuation<String, any Error>
    }

    public static let supportedShells: Set<String> = ["bash", "zsh", "fish"]
    public static let requestPayload = Data("\u{1B}[777;1~".utf8)

    private static let clearPayload = Data("\u{1B}[777;2~".utf8)
    private static let bracketedPasteStart = Data("\u{1B}[200~".utf8)
    private static let bracketedPasteEnd = Data("\u{1B}[201~".utf8)

    private var request: Request?
    private var timeoutTask: Task<Void, Never>?

    public var hasPendingRequest: Bool { request != nil }

    public init() {}

    public func read(isAvailable: Bool, write: @escaping Write) async throws -> String {
        guard isAvailable else { throw TerminalDraftError.unavailable }
        guard request == nil else { throw TerminalDraftError.alreadyPending }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request = Request(id: id, continuation: continuation)
                Task { await write(Self.requestPayload) }
                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.cancel(id: id, error: TerminalDraftError.timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id, error: CancellationError())
            }
        }
    }

    public func receive(_ draft: String) {
        guard let request else { return }
        finish(request)
        request.continuation.resume(returning: draft)
    }

    public func cancel(_ error: any Error = TerminalDraftError.unavailable) {
        guard let request else { return }
        cancel(id: request.id, error: error)
    }

    public func replacementPayload(for command: String) -> Data {
        var data = Self.clearPayload
        data.append(Self.bracketedPasteStart)
        data.append(Data(command.utf8))
        data.append(Self.bracketedPasteEnd)
        return data
    }

    private func cancel(id: UUID, error: any Error) {
        guard request?.id == id, let request else { return }
        finish(request)
        request.continuation.resume(throwing: error)
    }

    private func finish(_ request: Request) {
        guard self.request?.id == request.id else { return }
        self.request = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
