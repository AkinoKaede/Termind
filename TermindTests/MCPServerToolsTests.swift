import AgentKit
import Foundation
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct MCPServerToolsTests {
    @Test
    func exportsTheCompleteHostToolSet() {
        let server = makeMCPServerTools()
        let descriptors = server.descriptors

        #expect(descriptors.count == 13)
        #expect(Set(descriptors.map(\.name)) == MCPServerTools.exportedNames)
        for descriptor in descriptors {
            #expect(descriptor.inputSchema.objectValue?["type"]?.stringValue == "object")
        }
    }

    @Test
    func externalSSHExecSchemaOffersBoundSecretBrokerFields() throws {
        let descriptor = try #require(
            makeMCPServerTools().descriptors.first { $0.name == "ssh_exec" }
        )
        let properties = try #require(
            descriptor.inputSchema.objectValue?["properties"]?.objectValue
        )

        #expect(properties["secret_handle"] != nil)
        #expect(properties["stdin_purpose"] != nil)
        #expect(properties["command"] != nil)
        #expect(makeMCPServerTools().contains("request_user_secret"))
    }

    @Test
    func disabledToolsAreAbsentAndCannotBeCalled() async {
        let server = makeMCPServerTools(disabledTools: ["sftp_delete"])

        #expect(!server.descriptors.contains { $0.name == "sftp_delete" })
        #expect(!server.contains("sftp_delete"))
        await #expect(throws: MCPServerToolsError.unknownTool("sftp_delete")) {
            _ = try await server.call(
                name: "sftp_delete", arguments: .object([:]), runID: UUID(),
                clientName: "Tests", callID: "disabled", secretBroker: SecretBroker()
            )
        }
    }

    @Test
    func listHostsReturnsUntrustedStructuredJSONWithoutPromptFraming() async throws {
        let server = makeMCPServerTools()
        let result = try await server.call(
            name: "list_hosts", arguments: .object([:]), runID: UUID(),
            clientName: "Tests", callID: "list", secretBroker: SecretBroker()
        )
        let payload = try #require(result.untrustedPayload)
        let object = try #require(try AgentJSONValue.decode(Data(payload.utf8)).objectValue)

        #expect(object["hosts"]?.arrayValue?.isEmpty == true)
        #expect(object["groups"]?.arrayValue?.isEmpty == true)
        #expect(!payload.contains("<untrusted-data>"))
        #expect(!result.isError)
    }

    @Test
    func secretPromptReturnsOnlyASessionBoundOneShotHandle() async throws {
        let authentication = ExternalAuthCoordinator()
        let server = makeMCPServerTools(externalAuthentication: authentication)
        let broker = SecretBroker()
        let runID = UUID()
        let hostID = UUID()
        let call = Task {
            try await server.call(
                name: "request_user_secret",
                arguments: .object([
                    "prompt": .string("Password for sudo"),
                    "host_id": .string(hostID.uuidString),
                    "consumer_tool": .string("ssh_exec"),
                    "purpose": .string("sudo password"),
                ]),
                runID: runID, clientName: "Claude Code", callID: "secret",
                secretBroker: broker
            )
        }
        try await waitForMCPCondition {
            if case .secret? = authentication.current?.request { return true }
            return false
        }
        if case .secret(let request)? = authentication.current?.request {
            #expect(request.timeout == .seconds(300))
        }
        authentication.respondSecret(
            .answered([
                AgentUserInputAnswer(questionID: "secret", value: .secret("TOP-SECRET"))
            ]))

        let result = try await call.value
        let payload = try #require(result.untrustedPayload)
        let object = try #require(try AgentJSONValue.decode(Data(payload.utf8)).objectValue)
        let rawHandle = try #require(object["secret_handle"]?.stringValue)
        let handle = SecretHandle(id: try #require(UUID(uuidString: rawHandle)))
        #expect(!payload.contains("TOP-SECRET"))
        #expect(await broker.count == 1)

        let consumed = try await broker.consume(
            handle,
            matching: SecretBinding(
                runID: runID, toolName: "ssh_exec", hostID: hostID,
                purpose: "sudo password"
            )
        )
        #expect(consumed == "TOP-SECRET")
        await #expect(throws: SecretBrokerError.notFound) {
            _ = try await broker.consume(
                handle,
                matching: SecretBinding(
                    runID: runID, toolName: "ssh_exec", hostID: hostID,
                    purpose: "sudo password"
                )
            )
        }
    }

    @Test
    func timedOutSecretPromptReturnsAnErrorAndIssuesNoHandle() async throws {
        let authentication = ExternalAuthCoordinator()
        let server = makeMCPServerTools(externalAuthentication: authentication)
        let broker = SecretBroker()
        let call = Task {
            try await server.call(
                name: "request_user_secret",
                arguments: .object([
                    "prompt": .string("Password for sudo"),
                    "host_id": .string(UUID().uuidString),
                    "consumer_tool": .string("ssh_exec"),
                    "purpose": .string("sudo password"),
                    "timeout_seconds": .number(17),
                ]),
                runID: UUID(), clientName: "Claude Code", callID: "secret-timeout",
                secretBroker: broker
            )
        }
        try await waitForMCPCondition {
            if case .secret? = authentication.current?.request { return true }
            return false
        }
        if case .secret(let request)? = authentication.current?.request {
            #expect(request.timeout == .seconds(17))
        }

        authentication.respondSecret(.timedOut)

        let result = try await call.value
        #expect(result.isError)
        #expect(result.content == "User input timed out after 17 seconds.")
        #expect(await broker.count == 0)
    }

    @Test
    func endingASessionCancelsItsPromptAndDiscardsSecrets() async throws {
        let authentication = ExternalAuthCoordinator()
        let server = makeMCPServerTools(externalAuthentication: authentication)
        let broker = SecretBroker()
        let runID = UUID()
        _ = await broker.issue(
            "secret",
            binding: SecretBinding(
                runID: runID, toolName: "ssh_exec", hostID: UUID(), purpose: "test"
            )
        )
        let prompt = Task {
            await authentication.enqueue(
                secretRequest(), clientName: "Client", runID: runID
            )
        }
        try await waitForMCPCondition { authentication.current != nil }

        await server.endSession(runID: runID, secretBroker: broker)

        #expect(await prompt.value == .cancelled)
        #expect(await broker.count == 0)
    }
}

@MainActor
func makeMCPServerTools(
    disabledTools: Set<String> = [],
    externalAuthentication: ExternalAuthCoordinator = ExternalAuthCoordinator(),
    hosts: [Termind.Host] = [],
    metrics: any MetricsSnapshotReading = TestMetricsReader()
) -> MCPServerTools {
    let store = HostLibraryModel(hosts: hosts)
    let resolver = AgentHostResolver(store: store)
    return MCPServerTools(
        hosts: resolver, metrics: metrics,
        connections: AgentConnectionPool(
            configuration: { _ in throw MCPTestFailure.unused },
            routeFingerprint: { _ in throw MCPTestFailure.unused },
            openExec: { _ in throw MCPTestFailure.unused },
            openSFTP: { _ in throw MCPTestFailure.unused },
            sweepInterval: nil
        ),
        authentication: AgentSSHAuthenticationRegistry(resolver: resolver),
        background: AgentBackgroundCommands(sweepInterval: nil),
        externalAuthentication: externalAuthentication,
        history: ToolAuditModel(), disabledTools: disabledTools
    )
}

private func secretRequest() -> AgentUserInputRequest {
    AgentUserInputRequest(
        questions: [AgentUserQuestion(id: "secret", prompt: "Secret", kind: .secret)],
        purpose: "test", hostID: UUID()
    )
}

@MainActor
private func waitForMCPCondition(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    throw MCPTestFailure.timedOut
}

private enum MCPTestFailure: Error { case unused, timedOut }
