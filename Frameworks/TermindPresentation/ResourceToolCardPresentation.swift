// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

nonisolated public enum ResourceToolCardPresentation {
    enum Resource: String {
        case host, hostGroup, identity, key, forwarding, snippet, package, metrics
    }

    static func resource(_ name: String) -> Resource? {
        switch name {
        case TermindToolName.listHosts, TermindToolName.getHost, TermindToolName.addHost,
            TermindToolName.editHost, TermindToolName.deleteHost:
            .host
        case TermindToolName.listHostGroups, TermindToolName.getHostGroup, TermindToolName.addHostGroup,
            TermindToolName.editHostGroup, TermindToolName.deleteHostGroup:
            .hostGroup
        case TermindToolName.listIdentities, TermindToolName.getIdentity, TermindToolName.addIdentity,
            TermindToolName.editIdentity, TermindToolName.deleteIdentity:
            .identity
        case TermindToolName.listKeys, TermindToolName.getKey, TermindToolName.addKey,
            TermindToolName.editKey, TermindToolName.deleteKey, TermindToolName.generateKey:
            .key
        case TermindToolName.listPortForwardings, TermindToolName.getPortForwarding,
            TermindToolName.addPortForwarding, TermindToolName.editPortForwarding,
            TermindToolName.deletePortForwarding, TermindToolName.startPortForwarding,
            TermindToolName.stopPortForwarding:
            .forwarding
        case TermindToolName.listSnippets, TermindToolName.getSnippet, TermindToolName.addSnippet,
            TermindToolName.editSnippet, TermindToolName.deleteSnippet:
            .snippet
        case TermindToolName.listSnippetPackages, TermindToolName.getSnippetPackage,
            TermindToolName.addSnippetPackage, TermindToolName.editSnippetPackage,
            TermindToolName.deleteSnippetPackage:
            .package
        case TermindToolName.listMetrics, TermindToolName.getMetrics, TermindToolName.addMetrics,
            TermindToolName.editMetrics, TermindToolName.deleteMetrics, TermindToolName.startMetrics,
            TermindToolName.stopMetrics, TermindToolName.refreshMetrics:
            .metrics
        default: nil
        }
    }

    public static func supports(_ descriptor: AgentToolDescriptor) -> Bool {
        descriptor.target != .mcp && resource(descriptor.name) != nil
    }

    public static func content(for card: AgentToolCard, locale: Locale = .current) -> ResourceToolCardContent? {
        guard supports(card.descriptor), let resource = resource(card.descriptor.name), let result = card.result else {
            return nil
        }
        let value = try? AgentJSONValue.decode(Data((result.untrustedPayload ?? result.content).utf8))
        var names = result.metadata["resource_display_names"]?.objectValue ?? [:]
        func includeGroups(_ values: [AgentJSONValue], parent: String = "") {
            for value in values {
                guard let group = value.objectValue, let id = group["id"]?.stringValue else { continue }
                let name = group["name"]?.stringValue ?? ""
                let path = group["path"]?.stringValue ?? [parent, name].filter { !$0.isEmpty }.joined(separator: " / ")
                if !path.isEmpty { names[id] = .string(path) }
                includeGroups(group["children"]?.arrayValue ?? [], parent: path)
            }
        }
        includeGroups(value?.objectValue?["groups"]?.arrayValue ?? [])
        let projection = Projection(locale: locale, names: names)
        if result.isError || [.failed, .denied, .interrupted].contains(card.state) {
            return projection.failure(value, raw: result.content, state: card.state)
        }
        guard let object = value?.objectValue else { return projection.unavailable() }
        var content: ResourceToolCardContent
        let listKey: String =
            switch resource {
            case .host: "hosts"
            case .hostGroup: "host_groups"
            case .identity: "identities"
            case .key: "keys"
            case .forwarding: "port_forwardings"
            case .snippet: "snippets"
            case .package: "snippet_packages"
            case .metrics: "metrics"
            }
        if let values = object[listKey]?.arrayValue {
            content = .init()
            content.isList = true
            content.title = projection.text(AppStrings.ResourceCards.resourceCount(values.count))
            content.rows = values.compactMap { value in
                guard let fields = value.objectValue else { return nil }
                let card = projection.project(fields, resource: resource)
                let parts =
                    (fields["address"]?.stringValue.map { [$0] } ?? [])
                    + card.fields.map(\.value) + card.route.map(\.value)
                return .init(title: card.title, subtitle: parts.joined(separator: " · "))
            }
            if values.isEmpty {
                content.notices = [.message(projection.text(AppStrings.ResourceCards.empty), .secondary)]
            }
        } else if object["deleted"]?.boolValue == true {
            content = .init()
            content.title = projection.reference(object["id"]?.stringValue)
            if let id = object["id"]?.stringValue, names[id] == nil {
                content.details.append(projection.field("resource", id))
            }
            content.notices = [.message(projection.text(AppStrings.ResourceCards.deleted), .success)]
        } else {
            content = projection.project(object, resource: resource)
            if resource == .host, let args = card.invocation.call.arguments.objectValue {
                let advanced = args.filter {
                    Self.advancedHostFields.contains($0.key) && $0.value != .null
                }
                if !advanced.isEmpty {
                    for item in projection.arguments(advanced, resource: .host, deleting: false) {
                        switch item {
                        case .field(let field): content.details.append(field)
                        case .text(let block):
                            content.blocks.append(
                                .init(
                                    title: block.title ?? "", text: block.text, monospaced: block.style == .monospaced,
                                    previewLines: 2, expandedOnly: true))
                        default: break
                        }
                    }
                }
            }
        }
        if card.descriptor.name == TermindToolName.startMetrics
            || card.descriptor.name == TermindToolName.startPortForwarding
        {
            content.notices.append(.message(projection.text(AppStrings.ResourceTools.startRequested), .secondary))
        }
        if card.descriptor.name == TermindToolName.refreshMetrics {
            content.notices.append(
                .message(
                    projection.text(
                        object["refresh_requested"]?.boolValue == true
                            ? AppStrings.ResourceTools.refreshRequested : AppStrings.ResourceTools.refreshNotRequested),
                    .secondary))
        }
        return content
    }

    private static let advancedHostFields: Set<String> = [
        "tags", "ssh_charset", "telnet_charset", "sftp_initial_path", "icon_override_id", "shell_integration",
        "agent_forwarding_enabled", "forwarding_max_connections", "environment_variables",
        "mosh_enabled", "mosh_udp_port_range", "eternal_terminal_enabled", "eternal_terminal_port",
        "default_transport", "session_persistence_enabled", "session_backend", "session_on_connect",
        "wake_mac_address", "automatically_wake",
    ]

    static func approval(
        _ card: AgentToolCard, names: [String: AgentJSONValue], locale: Locale
    ) -> [AgentToolDetail.Item]? {
        guard supports(card.descriptor), let resource = resource(card.descriptor.name) else { return nil }
        let projection = Projection(locale: locale, names: names)
        return projection.arguments(
            card.invocation.call.arguments.objectValue ?? [:], resource: resource,
            deleting: card.descriptor.presentation?.actionKind == .delete)
    }

}
