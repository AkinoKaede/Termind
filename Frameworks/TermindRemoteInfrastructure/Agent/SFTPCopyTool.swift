import AgentKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated public struct SFTPCopyTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_copy", present: present, presentArguments: presentArguments
    )
    public let hosts: AgentHostResolver
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool

    public init(
        hosts: AgentHostResolver, authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool
    ) {
        self.hosts = hosts
        self.authentication = authentication
        self.connections = connections
    }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "sftp_copy",
            "Copy a regular file or directory recursively between hosts using streamed SFTP. "
                + "Preserves names and empty directories, not permissions or timestamps. Never deletes the source.",
            properties: [
                "source_host_id": Self.string(), "source_path": Self.string(max: 4_096),
                "destination_host_id": Self.string(),
                "destination_path": Self.described(Self.string(max: 4_096), "An existing destination directory."),
                "conflict_policy": Self.described(
                    Self.enumeration(["skip", "replace", "keep_both"]),
                    "Defaults to skip. Same-name directories merge. Replace may delete conflicting target directories."
                ),
            ],
            required: ["source_host_id", "source_path", "destination_host_id", "destination_path"],
            target: .host, approvalPolicy: .ask, concurrency: .sequential,
            presentation: .init(
                symbol: "doc.on.doc", activity: .semanticArgument(key: "source_path", fallback: .remoteFile),
                output: .json, actionKind: .copy
            )
        )
    }

    private struct Request: Sendable {
        var sourceHostID: UUID
        var sourcePath: String
        var destinationHostID: UUID
        var destinationPath: String
        var policy: TransferConflictPolicy

        init(_ invocation: AgentToolInvocation) throws {
            let arguments = try Arguments(invocation)
            sourceHostID = try arguments.uuid("source_host_id")
            destinationHostID = try arguments.uuid("destination_host_id")
            sourcePath = try AgentToolSupport.normalizeRemotePath(arguments.string("source_path"))
            destinationPath = try AgentToolSupport.normalizeRemotePath(arguments.string("destination_path"))
            switch arguments.optionalString("conflict_policy") ?? "skip" {
            case "skip": policy = .skip
            case "replace": policy = .replace
            case "keep_both": policy = .keepBoth
            default: throw AgentToolError.invalidArguments("Unknown SFTP conflict policy.")
            }
            let name = (sourcePath as NSString).lastPathComponent
            let target = destinationPath == "/" ? "/\(name)" : destinationPath + "/" + name
            guard sourcePath != "/", sourceHostID != destinationHostID || target != sourcePath else {
                throw AgentToolError.invalidPath
            }
        }
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let request = try Request(invocation)
        let listing = await hosts.listing().hosts
        guard let source = listing.first(where: { $0.id == request.sourceHostID }),
            let destination = listing.first(where: { $0.id == request.destinationHostID })
        else { throw AgentToolError.invalidHost }
        var checked = invocation
        checked.targetHostID = request.destinationHostID
        return AgentToolPreflight(
            invocation: checked, approvalPolicy: .ask,
            reasons: [
                "\(source.displayName) (\(source.id)): \(request.sourcePath) → "
                    + "\(destination.displayName) (\(destination.id)): \(request.destinationPath)"
            ],
            executionMetadata: [
                "source_host_name": .string(source.displayName),
                "destination_host_name": .string(destination.displayName),
            ]
        )
    }

    public func execute(
        _ invocation: AgentToolInvocation, context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        let request = try Request(invocation)
        let cancellation = TransferCancellationToken()
        return try await withTaskCancellationHandler {
            let permit = try await connections.sftpConcurrencyScheduler.acquire(
                anchorHostID: request.destinationHostID,
                hostIDs: [request.sourceHostID, request.destinationHostID],
                source: .agentRun(context.runID),
                byteCount: nil
            )
            do {
                let result = try await authentication.withSFTP(
                    hostID: request.sourceHostID, invocationID: invocation.id,
                    interaction: context.sshInteraction, pool: connections, cancellation: cancellation,
                    runID: context.runID, schedulesDataTransfer: true, concurrencyPermit: permit
                ) { source in
                    if request.sourceHostID == request.destinationHostID,
                        permit.schedulingMode == .channelsOnly
                    {
                        return await performCopy(
                            source: source, destination: source,
                            request: request, invocation: invocation,
                            context: context, cancellation: cancellation)
                    }
                    return try await authentication.withSFTP(
                        hostID: request.destinationHostID, invocationID: invocation.id,
                        interaction: context.sshInteraction, pool: connections, cancellation: cancellation,
                        runID: context.runID, schedulesDataTransfer: true, concurrencyPermit: permit
                    ) { destination in
                        await performCopy(
                            source: source, destination: destination,
                            request: request, invocation: invocation,
                            context: context, cancellation: cancellation)
                    }
                }
                await permit.release()
                return result
            } catch {
                await permit.release()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func performCopy(
        source: any SFTPClientProtocol,
        destination: any SFTPClientProtocol,
        request: Request,
        invocation: AgentToolInvocation,
        context: AgentToolExecutionContext,
        cancellation: TransferCancellationToken
    ) async -> AgentToolResult {
        let outcome = await SFTPRemoteCopyOperation.run(
            sourcePath: request.sourcePath, destinationPath: request.destinationPath,
            sameHost: request.sourceHostID == request.destinationHostID,
            source: source, destination: destination, policy: request.policy,
            cancellation: cancellation
        ) { outcome, progress in
            context.report(Self.copyResult(invocation, request, context, outcome, progress: progress))
        }
        return Self.copyResult(invocation, request, context, outcome)
    }

    private static func copyResult(
        _ invocation: AgentToolInvocation, _ request: Request, _ context: AgentToolExecutionContext,
        _ outcome: SFTPRemoteCopyOperation.Outcome, progress: SFTPProgress? = nil
    ) -> AgentToolResult {
        var object: [String: AgentJSONValue] = [
            "source_host_id": .string(request.sourceHostID.uuidString), "source_path": .string(request.sourcePath),
            "destination_host_id": .string(request.destinationHostID.uuidString),
            "destination_path": .string(request.destinationPath),
            "actual_destination_path": .string(outcome.actualDestinationPath),
            "conflict_policy": .string(request.policy == .keepBoth ? "keep_both" : request.policy.rawValue),
            "copied_files": .number(Double(outcome.copiedFiles)),
            "created_directories": .number(Double(outcome.createdDirectories)),
            "skipped_items": .number(Double(outcome.skippedItems)), "bytes": .number(Double(outcome.bytes)),
            "completed_bytes": .number(Double(outcome.bytes + (progress?.completedBytes ?? 0))),
            "total_bytes": .number(Double(outcome.totalBytes)),
            "bytes_per_second": .number(Double(progress?.bytesPerSecond ?? 0)),
        ]
        for key in ["source_host_name", "destination_host_name"] { object[key] = context.preflightMetadata[key] }
        if let error = outcome.error { object["error"] = .string(error) }
        if let path = outcome.failedPath { object["failed_path"] = .string(path) }
        var result = Self.result(invocation, .object(object))
        result.isError = outcome.error != nil
        return result
    }

    private static func fields(_ object: [String: AgentJSONValue], locale: Locale) -> [AgentToolDetail.Item] {
        func field(_ label: String.LocalizationValue, _ value: String) -> AgentToolDetail.Item {
            .field(
                .init(label: AppLocalization.string(label, locale: locale), value: value, isMonospaced: true))
        }
        var items: [AgentToolDetail.Item] = []
        let values: [(String.LocalizationValue, String)] = [
            ("Source host", "source_host_id"), ("Source path", "source_path"),
            ("Destination host", "destination_host_id"), ("Destination path", "destination_path"),
            ("Actual destination", "actual_destination_path"),
        ]
        for (label, key) in values {
            if let value = object[key]?.stringValue {
                let name =
                    key == "source_host_id"
                    ? object["source_host_name"]?.stringValue
                    : key == "destination_host_id" ? object["destination_host_name"]?.stringValue : nil
                items.append(field(label, name.map { "\($0) (\(value))" } ?? value))
            }
        }
        let policy = object["conflict_policy"]?.stringValue ?? "skip"
        let policyLabel: String.LocalizationValue =
            policy == "replace" ? "Replace" : policy == "keep_both" ? "Keep Both" : "Skip"
        items.append(field("Conflict policy", AppLocalization.string(policyLabel, locale: locale)))
        if policy == "replace" {
            items.append(
                .message(
                    AppLocalization.string("Overwrite may delete conflicting target directories.", locale: locale),
                    .warning
                ))
        }
        let counts: [(String.LocalizationValue, String)] = [
            ("Copied files", "copied_files"), ("Created directories", "created_directories"),
            ("Skipped items", "skipped_items"),
        ]
        for (label, key) in counts {
            if let value = object[key]?.integerValue { items.append(field(label, String(value))) }
        }
        for (label, key) in [
            (String.LocalizationValue("Completed bytes"), "completed_bytes"), ("Total bytes", "total_bytes"),
        ] {
            if let value = object[key]?.integerValue {
                items.append(field(label, AgentToolDetailFormatting.byteCount(value)))
            }
        }
        if let value = object["bytes_per_second"]?.integerValue {
            items.append(field("Transfer speed", AgentToolDetailFormatting.byteCount(value) + "/s"))
        }
        if let path = object["failed_path"]?.stringValue { items.append(field("Failed path", path)) }
        if let error = object["error"]?.stringValue { items.append(.message(error, .failure)) }
        return items
    }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        AgentToolDetailFormatting.objectItems(input) { fields($0, locale: input.locale) }
    }

    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        fields(input.arguments, locale: input.locale)
    }
}
