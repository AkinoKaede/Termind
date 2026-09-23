import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized)
@MainActor
struct MCPServerToolsTests {
    @Test
    func downloadTicketAndStatusUseTheExecutorWithoutOpeningSSHOrLocalFiles() async throws {
        let host = TermindDomain.Host(name: "Download", host: "download.example")
        let server = makeMCPServerTools(hosts: [host])
        server.configureTransfers(port: 7391)
        let runID = UUID()
        let broker = SecretBroker()
        let result = try await server.call(
            name: "sftp_download",
            arguments: .object([
                "host_id": .string(host.id.uuidString), "remote_path": .string("/source/a.zip"),
            ]), runID: runID, clientName: "Tests", callID: "download", secretBroker: broker
        )
        #expect(!result.isError)
        let payload = try #require(result.untrustedPayload)
        let ticket = try #require(try AgentJSONValue.decode(Data(payload.utf8)).objectValue)
        let token = try #require(ticket["download_token"]?.stringValue)
        #expect(token.count == 43)
        #expect(ticket["method"] == .string("GET"))
        #expect(ticket["headers"]?.objectValue?["Authorization"] == .string("Bearer \(token)"))
        #expect(ticket["download_url"]?.stringValue?.hasPrefix("http://127.0.0.1:7391/downloads/") == true)
        let status = try await server.call(
            name: "sftp_download_status", arguments: .object(["download_id": ticket["download_id"]!]),
            runID: runID, clientName: "Tests", callID: "status", secretBroker: broker
        )
        #expect(!status.isError)
        let initial = try #require(try AgentJSONValue.decode(Data(status.untrustedPayload!.utf8)).objectValue)
        #expect(initial["status"] == .string("waiting"))
        #expect(initial["byte_count"] == .null)
        #expect(initial["sha256"] == .null)
        let crossSession = try await server.call(
            name: "sftp_download_status", arguments: .object(["download_id": ticket["download_id"]!]),
            runID: UUID(), clientName: "Other", callID: "other", secretBroker: SecretBroker()
        )
        #expect(crossSession.isError)
        await server.endSession(runID: runID, secretBroker: broker)
        #expect(throws: MCPDownloadError.self) {
            try server.downloads.status(id: UUID(uuidString: ticket["download_id"]!.stringValue!)!, runID: runID)
        }
    }

    @Test
    func externalUploadTicketAndStatusUseTheMCPExecutorWithoutOpeningFilesOrSSH() async throws {
        let host = TermindDomain.Host(name: "Upload", host: "upload.example")
        let server = makeMCPServerTools(hosts: [host])
        server.uploads.configure(port: 7391)
        let runID = UUID()
        let broker = SecretBroker()
        let result = try await server.call(
            name: "sftp_upload",
            arguments: .object([
                "host_id": .string(host.id.uuidString), "remote_path": .string("/target/a.zip"),
                "byte_count": .number(0),
                "sha256": .string("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ]), runID: runID, clientName: "Tests", callID: "upload", secretBroker: broker
        )
        #expect(!result.isError)
        let payload = try #require(result.untrustedPayload)
        let ticket = try #require(try AgentJSONValue.decode(Data(payload.utf8)).objectValue)
        let token = try #require(ticket["upload_token"]?.stringValue)
        #expect(token.count == 43)
        #expect(ticket["headers"]?.objectValue?["Authorization"] == .string("Bearer \(token)"))
        #expect(ticket["upload_url"]?.stringValue?.hasPrefix("http://127.0.0.1:7391/uploads/") == true)
        #expect(ticket["method"] == .string("PUT"))
        let status = try await server.call(
            name: "sftp_upload_status", arguments: .object(["upload_id": ticket["upload_id"]!]),
            runID: runID, clientName: "Tests", callID: "status", secretBroker: broker
        )
        #expect(!status.isError)
        #expect(status.untrustedPayload?.contains("waiting") == true)
        let other = try await server.call(
            name: "sftp_upload_status", arguments: .object(["upload_id": ticket["upload_id"]!]),
            runID: UUID(), clientName: "Other", callID: "status-other", secretBroker: SecretBroker()
        )
        #expect(other.isError)
        await server.endSession(runID: runID, secretBroker: broker)
        #expect(throws: MCPUploadError.self) {
            try server.uploads.status(id: UUID(uuidString: ticket["upload_id"]!.stringValue!)!, runID: runID)
        }
    }

    @Test
    func exportsTheCompleteActingHostSubsetAndTransferTools() {
        let server = makeMCPServerTools()
        let descriptors = server.descriptors
        let resolver = AgentHostResolver(store: HostLibraryModel())
        let connections = AgentConnectionPool(
            configuration: { _ in throw MCPTestFailure.unused },
            routeFingerprint: { _ in throw MCPTestFailure.unused },
            openConnection: { _ in throw MCPTestFailure.unused },
            openSFTP: { _ in throw MCPTestFailure.unused },
            sweepInterval: nil
        )
        let acting = AgentToolRegistry(
            TermindAgentTools.tools(
                in: .init(
                    hosts: resolver, metrics: TestMetricsReader(), connections: connections,
                    authentication: AgentSSHAuthenticationRegistry(resolver: resolver),
                    background: AgentBackgroundCommands(sweepInterval: nil)
                ))
        ).available(in: .acting)
        let transferNames: Set<String> = [
            "sftp_upload", "sftp_upload_status", "sftp_download", "sftp_download_status",
        ]
        let runtimeNames: Set<String> = ["request_user_secret"]
        let sharedNames = MCPServerTools.exportedNames.subtracting(transferNames).subtracting(runtimeNames)
        let excludedNames: Set<String> = [
            "terminal_suggest", "scratch_pull", "scratch_push", "scratch_list", "scratch_read",
            "scratch_write", "scratch_edit", "scratch_diff", "scratch_delete", "fetch", "web_search",
            "skill_read_file", "skill_install", "skill_manage", "present_plan", "manage_tasks",
        ]

        #expect(descriptors.count == 18)
        #expect(Set(descriptors.map(\.name)) == MCPServerTools.exportedNames)
        #expect(excludedNames.isDisjoint(with: MCPServerTools.exportedNames))
        #expect(sharedNames.isSubset(of: Set(acting.descriptors.map(\.name))))
        for name in sharedNames {
            #expect(server.descriptors.first { $0.name == name } == acting[name]?.descriptor)
        }
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
        try AgentJSONSchemaValidator.validate(
            .object(["host_id": .string(UUID().uuidString), "command": .string("uname -a")]),
            against: descriptor.inputSchema
        )
        #expect(descriptor.summary.contains("do not call request_user_secret for SSH login"))
        #expect(properties["secret_handle"]?.objectValue?["description"]?.stringValue?.contains("Omit when") == true)
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
                AgentUserInputAnswer(
                    questionID: "secret", value: .secret(agentSecret("TOP-SECRET"))
                )
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
        #expect(try consumed.withUnsafeBytes { Array($0) } == Array("TOP-SECRET".utf8))
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
        _ = try await broker.issue(
            agentSecret("secret"),
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
    hosts: [TermindDomain.Host] = [],
    metrics: any MetricsSnapshotReading = TestMetricsReader()
) -> MCPServerTools {
    let store = HostLibraryModel(hosts: hosts)
    let resolver = AgentHostResolver(store: store)
    return MCPServerTools(
        hosts: resolver, metrics: metrics,
        connections: AgentConnectionPool(
            configuration: { _ in throw MCPTestFailure.unused },
            routeFingerprint: { _ in throw MCPTestFailure.unused },
            openConnection: { _ in throw MCPTestFailure.unused },
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
