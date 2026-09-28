import Foundation
import TermindDomain

public nonisolated struct SecurityKeyAssertion: Hashable, Sendable {
    public var credentialID: Data
    public var authenticatorData: Data
    public var clientDataJSON: Data
    public var signature: Data

    public init(credentialID: Data, authenticatorData: Data, clientDataJSON: Data, signature: Data) {
        self.credentialID = credentialID
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
        self.signature = signature
    }

    public var userPresent: Bool {
        authenticatorData.count >= 37 && authenticatorData[authenticatorData.startIndex + 32] & 1 != 0
    }
    public var userVerified: Bool {
        authenticatorData.count >= 37 && authenticatorData[authenticatorData.startIndex + 32] & 4 != 0
    }
}

public nonisolated struct SecurityKeySigningRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var hostID: UUID
    public var hostname: String
    public var keyName: String
    public var credential: SecurityKeyCredential
    public var challenge: Data
    public var allowsUserInteraction: Bool

    public init(
        hostID: UUID, hostname: String, credential: SecurityKeyCredential, challenge: Data,
        allowsUserInteraction: Bool = true, keyName: String = "Security Key"
    ) {
        self.hostID = hostID
        self.hostname = hostname
        self.keyName = keyName
        self.credential = credential
        self.challenge = challenge
        self.allowsUserInteraction = allowsUserInteraction
    }
}

public typealias SecurityKeySigningHandler = @Sendable (SecurityKeySigningRequest) async throws -> SecurityKeyAssertion

@MainActor
@Observable
public final class SecurityKeySigningCoordinator {
    public private(set) var pending: SecurityKeySigningRequest?
    private var continuation: CheckedContinuation<SecurityKeyAssertion, any Error>?

    public init() {}

    public func sign(_ request: SecurityKeySigningRequest) async throws -> SecurityKeyAssertion {
        // Each connection serializes authentication; reject overlapping auxiliary requests.
        guard request.allowsUserInteraction, pending == nil else { throw SSHInteractionRequired() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                pending = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.respond(request.id, result: .failure(CancellationError()))
            }
        }
    }

    public func respond(_ id: UUID, result: Result<SecurityKeyAssertion, any Error>) {
        guard pending?.id == id else { return }
        let continuation = continuation
        self.continuation = nil
        pending = nil
        continuation?.resume(with: result)
    }

    public func cancel() {
        if let pending { respond(pending.id, result: .failure(CancellationError())) }
    }
}
