import Foundation

nonisolated struct AgentToolExecutionContext: Sendable {
    var runID: UUID
    var userIntent: String
    var secretBroker: SecretBroker
    var userInteraction: any AgentUserInteractionHandling
    var preflightMetadata: [String: AgentJSONValue]
    var authorize: @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision
    /// What the call has produced so far.
    ///
    /// Pi's `onUpdate`, which it passes as a fourth argument to `execute`
    /// because it has no per-call context object to put it in. This is
    /// addressed to the reader and not to the model: the transcript gets the
    /// value the tool finally returns, never a partial one, so a tool may
    /// report as often as it likes without inflating anything the model pays
    /// for. Defaults to discarding, so a caller assembling a context by hand —
    /// a test, a preview — need not care.
    var report: @Sendable (AgentToolResult) -> Void = { _ in }
    /// Returns once the user has said something that is queued for the next
    /// model boundary — immediately, if something already is.
    ///
    /// For a tool that is deliberately waiting, so a person interjecting does
    /// not have to sit out a fifteen-minute deadline first. A tool opts into
    /// this rather than having it done to it, because whether stopping early is
    /// free depends entirely on what is being stopped: giving up on `ssh_wait`
    /// costs nothing, while giving up on `ssh_exec` would strand a
    /// half-finished command on a host.
    var whenUserInterjects: @Sendable () async -> Void = { }
}

nonisolated protocol AgentTool: Sendable {
    var descriptor: AgentToolDescriptor { get }
    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight
    func execute(
        _ invocation: AgentToolInvocation,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolResult
}

/// A locally owned tool definition.
///
/// The executable behavior and its trusted transcript projection travel as one
/// value. `AgentToolCatalog` type-erases definitions only after registration,
/// so adding a tool cannot require a second presenter-only registration.
nonisolated protocol AgentToolDefinition: AgentTool {
    static var presenter: AgentToolDetailPresenter { get }
}

nonisolated extension AgentToolDefinition {
    /// Binds the executable definition to its presenter without asking every
    /// descriptor declaration to repeat a string ID.
    var registeredDescriptor: AgentToolDescriptor {
        var registered = descriptor
        guard var presentation = registered.presentation else {
            precondition(
                false, "A registered local tool must declare presentation metadata"
            )
            return registered
        }
        presentation.presenterID = Self.presenter.id
        registered.presentation = presentation
        return registered
    }
}

nonisolated extension AgentTool {
    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        AgentToolPreflight(invocation: invocation, safety: descriptor.safety)
    }
}

nonisolated struct AnyAgentTool: AgentTool, Sendable {
    let descriptor: AgentToolDescriptor
    private let executeClosure:
        @Sendable (AgentToolInvocation, AgentToolExecutionContext) async throws -> AgentToolResult
    private let preflightClosure: @Sendable (AgentToolInvocation) async throws -> AgentToolPreflight

    init<T: AgentToolDefinition>(_ tool: T) {
        descriptor = tool.registeredDescriptor
        preflightClosure = tool.preflight
        executeClosure = tool.execute
    }

    init<T: AgentTool>(_ tool: T) {
        descriptor = tool.descriptor
        preflightClosure = tool.preflight
        executeClosure = tool.execute
    }

    init(
        descriptor: AgentToolDescriptor,
        preflight: (@Sendable (AgentToolInvocation) async throws -> AgentToolPreflight)? = nil,
        execute: @escaping @Sendable (
            AgentToolInvocation, AgentToolExecutionContext
        ) async throws -> AgentToolResult
    ) {
        self.descriptor = descriptor
        preflightClosure = preflight ?? { invocation in
            AgentToolPreflight(invocation: invocation, safety: descriptor.safety)
        }
        executeClosure = execute
    }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        try await preflightClosure(invocation)
    }

    func execute(
        _ invocation: AgentToolInvocation,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        try await executeClosure(invocation, context)
    }
}
