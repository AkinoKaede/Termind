// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated struct ResourceToolSpecification: Sendable, AgentToolSchemaBuilding {
    enum Resource: String, CaseIterable, Sendable {
        case host, identity, key, snippet, metrics
        case hostGroup = "host_group"
        case portForwarding = "port_forwarding"
        case snippetPackage = "snippet_package"

        var idField: String { self == .metrics ? "host_id" : rawValue + "_id" }
        var activity: AgentToolDescriptor.Presentation.ActivityKind {
            switch self {
            case .host: .hosts
            case .hostGroup: .hostGroups
            case .identity: .identities
            case .key: .keys
            case .snippet: .snippets
            case .snippetPackage: .snippetPackages
            case .portForwarding: .portForwardings
            case .metrics: .metrics
            }
        }
        var symbol: String {
            switch self {
            case .host: "server.rack"
            case .hostGroup: "folder"
            case .identity: "person.crop.circle"
            case .key: "key"
            case .snippet: "text.alignleft"
            case .snippetPackage: "folder"
            case .portForwarding: "arrow.triangle.branch"
            case .metrics: "gauge.with.dots.needle.67percent"
            }
        }
    }

    enum Action: String, Sendable {
        case list, get, add, edit, delete, generate, start, stop, refresh
        var readOnly: Bool { self == .list || self == .get }
        var presentation: AgentToolDescriptor.Presentation.ActionKind {
            switch self {
            case .list: .list
            case .get: .read
            case .add: .add
            case .generate: .generate
            case .edit: .edit
            case .delete: .delete
            case .start: .start
            case .refresh: .refresh
            case .stop: .stop
            }
        }
    }

    let resource: Resource
    let action: Action
    var clearableFields: Set<String> {
        guard action == .edit else { return [] }
        switch resource {
        case .host:
            return [
                "group_id", "ssh_identity_id", "telnet_identity_id", "jump_host_id", "startup_snippet_id",
                "proxy", "telnet_proxy", "tags", "environment_variables", "icon_override_id",
                "sftp_initial_path", "wake_mac_address",
            ]
        case .hostGroup: return ["parent_id"]
        case .identity: return ["password", "key_id", "notes"]
        case .key: return ["passphrase", "certificate"]
        case .snippet: return ["package_id", "target_host_ids"]
        case .snippetPackage: return ["parent_id"]
        case .metrics: return ["disks", "interfaces"]
        case .portForwarding: return []
        }
    }

    static let all: [Self] = Resource.allCases.flatMap { resource in
        var actions: [Action] = [.list, .get, .add, .edit, .delete]
        // Keep list_hosts' existing discovery contract, including temporary targets.
        if resource == .host { actions.removeAll { $0 == .list } }
        if resource == .metrics {
            actions.removeAll { $0 == .get }
            actions += [.start, .stop, .refresh]
        }
        if resource == .key { actions.append(.generate) }
        if resource == .portForwarding { actions += [.start, .stop] }
        return actions.map { Self(resource: resource, action: $0) }
    }

    var schema: (properties: [String: AgentJSONValue], required: [String]) {
        var fields: [String: AgentJSONValue] = [:]
        var required: [String] = []
        if action != .list && action != .add && action != .generate || resource == .metrics && action == .add {
            fields[resource.idField] = Self.string(max: 36)
            required.append(resource.idField)
        }
        if action == .delete && resource == .snippetPackage {
            fields["keep_snippets"] = Self.described(
                Self.boolean(), "Defaults to true. False also deletes descendants' snippets.")
        }
        if action == .delete && resource == .hostGroup {
            fields["keep_hosts"] = Self.described(
                Self.boolean(), "Defaults to true. False explicitly deletes saved hosts in the subtree.")
        }
        if [.add, .edit, .generate].contains(action) {
            fields.merge(editableFields) { _, new in new }
            if action == .add || action == .generate {
                switch resource {
                case .host: required.append("address")
                case .hostGroup: required.append("name")
                case .identity: required += ["name", "username"]
                case .key:
                    if action == .add { required.append("private_key_secret_handle") }
                case .snippet: required += ["title", "body"]
                case .snippetPackage: required.append("name")
                case .portForwarding: required += ["host_id", "bind_port"]
                case .metrics: break
                }
            }
        }
        if !clearableFields.isEmpty {
            fields["clear_fields"] = Self.array(
                items: Self.enumeration(clearableFields.sorted()), max: clearableFields.count)
        }
        for key in fields.keys where !required.contains(key) {
            fields[key] = .object(["anyOf": .array([fields[key]!, .object(["type": .string("null")])])])
        }
        return (fields, required)
    }

    private var editableFields: [String: AgentJSONValue] {
        let color = Self.enumeration(TagColor.allCases.map(\.rawValue))
        let ids = Self.array(items: Self.string(max: 36), max: 1_000)
        let secret = Self.described(
            Self.string(max: 36), "Single-use handle returned by request_user_secret in this session. Never plaintext.")
        switch resource {
        case .host: return Self.hostFields
        case .hostGroup: return ["name": Self.string(max: 512), "parent_id": Self.string(max: 36)]
        case .identity:
            return [
                "name": Self.string(max: 512), "username": Self.string(max: 512), "notes": Self.string(max: 32_768),
                "key_id": Self.string(max: 36), "storage": Self.enumeration(["thisDevice", "iCloud"]),
                "color": color, "password_secret_handle": secret,
            ]
        case .key:
            var fields: [String: AgentJSONValue] = [
                "label": Self.string(max: 512), "storage": Self.enumeration(["thisDevice", "iCloud", "secureEnclave"]),
                "color": color, "certificate": Self.string(max: 32_768), "passphrase_secret_handle": secret,
                "save_passphrase": Self.boolean(),
            ]
            if action == .generate {
                fields["algorithm"] = Self.enumeration(["ed25519", "ecdsa", "rsa"])
                fields["bits"] = Self.integer(min: 256, max: 8192)
                fields["requires_user_presence"] = Self.boolean()
            } else {
                fields["private_key_secret_handle"] = secret
                fields["public_key"] = Self.string(max: 32_768)
            }
            return fields
        case .snippet:
            return [
                "title": Self.string(max: 512), "body": Self.string(max: 32_768), "color": color,
                "package_id": Self.string(max: 36), "target_host_ids": ids,
            ]
        case .snippetPackage:
            return ["name": Self.string(max: 512), "parent_id": Self.string(max: 36)]
        case .portForwarding:
            return [
                "host_id": Self.string(max: 36), "kind": Self.enumeration(["local", "remote", "dynamic"]),
                "bind_host": Self.string(max: 1024), "bind_port": Self.integer(min: 1, max: 65_535),
                "target_host": Self.string(max: 1024), "target_port": Self.integer(min: 1, max: 65_535),
                "label": Self.string(max: 512), "color": color,
            ]
        case .metrics:
            let devices = Self.array(items: Self.string(max: 1024), max: 1_000)
            return ["enabled": Self.boolean(), "disks": devices, "interfaces": devices]
        }
    }

    var summary: String {
        var text = "\(action.rawValue.capitalized) Termind \(resource.rawValue) configuration. "
        text +=
            "IDs are stable UUIDs. Omitted or null edit fields preserve existing values; clear_fields explicitly clears supported fields. "
        switch resource {
        case .host:
            text +=
                "Only saved hosts can be edited; list_hosts also discovers temporary targets. Associate reusable identities by ID; no inline credentials or host-private identities. "
            text += "Tailscale-discovered hosts are read-only here. Deletion uses the application's durable cleanup."
        case .hostGroup:
            text += "Parent cycles are invalid. Deletion keeps saved hosts ungrouped unless keep_hosts is false."
        case .identity, .key:
            text +=
                "Only public metadata is returned. Secrets require single-use request_user_secret handles, consumed after approval. "
            text += "No plaintext, credential references, private keys or hardware handles can be read or exported. "
            if resource == .key {
                text +=
                    "Software import and generation and Secure Enclave P-256 generation are supported; external hardware registration is not. "
                text +=
                    "save_passphrase defaults to true for supplied unlock material. Changing stored unlock material does not re-encrypt an existing key. "
            }
        case .snippet:
            text +=
                "list returns metadata; get includes the script body. Use run_snippet with an explicit host_id to execute."
        case .snippetPackage:
            text +=
                "Parent cycles are invalid. Deletion keeps snippets ungrouped unless keep_snippets is explicitly false."
        case .portForwarding:
            text +=
                "Returns configuration and runtime state. Editing an active rule stops it. Starting does not await authentication; resolve required actions in Termind. "
            text += "Application-owned forwarding survives the caller session."
        case .metrics:
            text +=
                "start/stop persist enabled state without removing the monitor. refresh requests a retry only if enabled and awake; it does not promise a fresh sample. "
            text +=
                "Read samples with get_metrics. Empty device arrays select none; clearing selects defaults. Collection is application-owned."
        }
        return text
    }
}

nonisolated struct ResourceManagementTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(
        id: "builtin.resource_management",
        layout: .init(boundsApprovalHeight: true),
        present: { publicSummary($0.result.objectValue ?? [:], locale: $0.locale) },
        presentArguments: { publicSummary($0.arguments, locale: $0.locale) })
    let specification: ResourceToolSpecification
    let manager: AgentResourceManager

    /// Full resource cards are composed by the application presentation layer.
    /// A bare registry must also fail closed rather than dumping protocol-shaped JSON.
    private static func publicSummary(_ object: [String: AgentJSONValue], locale: Locale) -> [AgentToolDetail.Item] {
        [
            ("name", "Name"), ("label", "Name"), ("title", "Title"),
            ("username", "Username"), ("address", "Address"), ("algorithm", "Algorithm"),
        ].compactMap { key, label in
            guard let value = object[key]?.stringValue, !value.isEmpty else { return nil }
            return AgentToolDetailFormatting.field(
                String.LocalizationValue(label), value, locale: locale)
        }
    }

    static func tools(manager: AgentResourceManager) -> [AnyAgentTool] {
        ResourceToolSpecification.all.filter {
            ![.host, .hostGroup, .metrics].contains($0.resource)
        }.map {
            AnyAgentTool(
                Self(specification: $0, manager: manager),
                availableIn: $0.action.readOnly ? [.planning, .acting] : [.acting])
        }
    }

    var descriptor: AgentToolDescriptor {
        let schema = specification.schema
        return Self.descriptor(
            specification.name, specification.summary, properties: schema.properties, required: schema.required,
            target: .local, approvalPolicy: specification.action.readOnly ? .approve : .ask,
            concurrency: specification.action.readOnly ? .parallel : .sequential,
            presentation: .init(
                symbol: specification.resource.symbol,
                activity: .semanticLabel(specification.resource.activity),
                output: .json, actionKind: specification.action.presentation))
    }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let args = try ResourceToolArguments(invocation.call.arguments, allowedClears: specification.clearableFields)
        // Validate handles without consuming capabilities before the approval gate.
        let handles = try args.values.keys.filter { $0.hasSuffix("_secret_handle") }.map { try args.uuid($0) }
        guard Set(handles).count == handles.count else { throw ResourceToolError.invalidInput }
        return AgentToolPreflight(invocation: invocation, approvalPolicy: descriptor.approvalPolicy)
    }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws -> AgentToolResult
    {
        do {
            let args = try ResourceToolArguments(
                invocation.call.arguments, allowedClears: specification.clearableFields)
            let previousNames = await manager.presentationNames(in: invocation.call.arguments)
            let output = try await manager.perform(specification, arguments: args, broker: context.secretBroker)
            let names = await manager.presentationNames(in: output).merging(previousNames) { current, _ in current }
            var result = Self.result(invocation, output)
            result.metadata["resource_display_names"] = .object(names)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ResourceToolError {
            throw error
        } catch is SecretBrokerError {
            throw SecretBrokerError.notFound
        } catch {
            // Parsers and Keychain errors must not smuggle input material into tool output.
            throw specification.resource == .key || specification.resource == .identity
                ? ResourceToolError.credentialFailed : ResourceToolError.saveFailed
        }
    }
}
