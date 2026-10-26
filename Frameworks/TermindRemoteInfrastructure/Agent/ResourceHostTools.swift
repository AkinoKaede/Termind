// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

extension ResourceToolSpecification {
    static var hostFields: [String: AgentJSONValue] {
        let proxy = object(
            properties: [
                "kind": enumeration(["http", "socks5"]), "address": string(max: 1024),
                "port": integer(min: 1, max: 65_535),
                "username": .object(["anyOf": .array([string(max: 512), .object(["type": .string("null")])])]),
                "identity_id": .object(["anyOf": .array([string(max: 36), .object(["type": .string("null")])])]),
            ], required: ["kind", "address", "port"])
        return [
            "name": string(max: 512), "address": string(max: 1024),
            "group_id": string(max: 36), "color": enumeration(TagColor.allCases.map(\.rawValue)),
            "tags": array(items: string(max: 512), max: 100),
            "ssh_enabled": boolean(), "ssh_port": integer(min: 1, max: 65_535),
            "ssh_identity_id": string(max: 36), "ssh_charset": enumeration(RemoteCharset.allCases.map(\.rawValue)),
            "telnet_enabled": boolean(), "telnet_port": integer(min: 1, max: 65_535),
            "telnet_identity_id": string(max: 36),
            "telnet_charset": enumeration(RemoteCharset.allCases.map(\.rawValue)),
            "jump_host_id": string(max: 36), "proxy": proxy, "telnet_proxy": proxy,
            "startup_snippet_id": string(max: 36), "sftp_initial_path": string(max: 4096),
            "icon_override_id": string(max: 512),
            "shell_integration": enumeration(HostShellIntegrationMode.allCases.map(\.rawValue)),
            "agent_forwarding_enabled": boolean(), "forwarding_max_connections": integer(min: 1, max: 64),
            "environment_variables": array(
                items: object(
                    properties: ["variable": string(max: 512), "value": string(max: 32_768)],
                    required: ["variable", "value"]), max: 100),
            "mosh_enabled": boolean(), "mosh_udp_port_range": string(max: 32),
            "eternal_terminal_enabled": boolean(), "eternal_terminal_port": integer(min: 1, max: 65_535),
            "default_transport": enumeration(["ssh", "mosh", "eternalTerminal"]),
            "session_persistence_enabled": boolean(),
            "session_backend": enumeration(SessionPersistenceBackendID.supported.map(\.rawValue)),
            "session_on_connect": enumeration(SessionPersistencePreferences.OnConnect.allCases.map(\.rawValue)),
            "wake_mac_address": string(max: 32), "automatically_wake": boolean(),
        ]
    }
}

extension AgentResourceManager {
    func manageHost(_ spec: ResourceToolSpecification, _ args: ResourceToolArguments) async throws -> AgentJSONValue {
        guard let hosts else { throw ResourceToolError.unsupported }
        if spec.resource == .hostGroup {
            return try manageHostGroup(spec.action, args, hosts: hosts)
        }
        let id = spec.action == .add ? UUID() : try args.uuid("host_id")
        let original = hosts.hosts.first { $0.id == id }
        guard spec.action == .add || original != nil else { throw ResourceToolError.notFound }
        let identityIDs = Set(credentials.managedIdentities.map(\.id))
        if spec.action == .get {
            return ResourceToolOutput.host(original!, reusableIdentityIDs: identityIDs)
        }
        guard original?.isTailscaleManaged != true else { throw ResourceToolError.unsupported }
        if spec.action == .delete {
            try hosts.deleteHost(id)
            return ResourceToolOutput.deleted(id)
        }
        var value = original ?? Host(id: id, name: "", host: "")
        value.name = args.text("name") ?? value.name
        value.host = args.text("address") ?? value.host
        value.groupID = try args.updatedID("group_id", previous: value.groupID)
        if let groupID = value.groupID {
            guard let group = hosts.groups.first(where: { $0.id == groupID }), group.tailscale == nil else {
                throw ResourceToolError.invalidReference
            }
        }
        value.colorTag = try args.enumValue("color", default: value.colorTag)
        value.tags = args.clears.contains("tags") ? [] : args.strings("tags") ?? value.tags
        value.sshEnabled = args.bool("ssh_enabled") ?? value.sshEnabled
        value.sshPort = args.int("ssh_port") ?? value.sshPort
        value.sshCharset = try args.enumValue("ssh_charset", default: value.sshCharset)
        value.telnetEnabled = args.bool("telnet_enabled") ?? value.telnetEnabled
        value.telnetPort = args.int("telnet_port") ?? value.telnetPort
        value.telnetCharset = try args.enumValue("telnet_charset", default: value.telnetCharset)
        for name in ["ssh_identity_id", "telnet_identity_id"] {
            if let selected = try args.optionalID(name), !identityIDs.contains(selected) {
                throw ResourceToolError.invalidReference
            }
        }
        value.sshIdentityID = try args.updatedID("ssh_identity_id", previous: value.sshIdentityID)
        value.telnetIdentityID = try args.updatedID("telnet_identity_id", previous: value.telnetIdentityID)
        value.jumpHostID = try args.updatedID("jump_host_id", previous: value.jumpHostID)
        value.startupSnippetID = try args.updatedID("startup_snippet_id", previous: value.startupSnippetID)
        if let snippetID = value.startupSnippetID, !snippets.snippets.contains(where: { $0.id == snippetID }) {
            throw ResourceToolError.invalidReference
        }
        value.proxy = try hostProxy("proxy", args: args, previous: value.proxy)
        value.telnetProxy = try hostProxy("telnet_proxy", args: args, previous: value.telnetProxy)
        value.sftpChannelInitialPath = args.clearedText("sftp_initial_path", previous: value.sftpChannelInitialPath)
        value.iconOverrideID =
            args.clears.contains("icon_override_id")
            ? nil
            : args.text("icon_override_id") ?? value.iconOverrideID
        value.shellIntegrationMode = try args.enumValue("shell_integration", default: value.shellIntegrationMode)
        value.agentForwardingEnabled = args.bool("agent_forwarding_enabled") ?? value.agentForwardingEnabled
        value.portForwardingMaxConnections =
            args.int("forwarding_max_connections") ?? value.portForwardingMaxConnections
        if args.clears.contains("environment_variables") { value.environmentVariables = [] }
        if let variables = args.values["environment_variables"]?.arrayValue {
            value.environmentVariables = try variables.map {
                guard let variable = $0.objectValue?["variable"]?.stringValue,
                    let content = $0.objectValue?["value"]?.stringValue
                else { throw ResourceToolError.invalidInput }
                return HostEnvironmentVariable(variable: variable, value: content)
            }
        }
        value.terminalTransports.moshEnabled = args.bool("mosh_enabled") ?? value.terminalTransports.moshEnabled
        value.terminalTransports.moshUDPPortRange =
            args.text("mosh_udp_port_range") ?? value.terminalTransports.moshUDPPortRange
        value.terminalTransports.eternalTerminalEnabled =
            args.bool("eternal_terminal_enabled") ?? value.terminalTransports.eternalTerminalEnabled
        value.terminalTransports.eternalTerminalPort =
            args.int("eternal_terminal_port") ?? value.terminalTransports.eternalTerminalPort
        value.terminalTransports.defaultTransport =
            try args.enumValue("default_transport", default: value.terminalTransports.defaultTransport)
        value.terminalTransports.normalizeDefault(isTailscaleManaged: false)
        value.sessionPersistence.enabled =
            args.bool("session_persistence_enabled") ?? value.sessionPersistence.enabled
        value.sessionPersistence.backend = try args.enumValue(
            "session_backend", default: value.sessionPersistence.backend)
        value.sessionPersistence.onConnect =
            try args.enumValue("session_on_connect", default: value.sessionPersistence.onConnect)
        value.wakeOnLAN.macAddress = args.clearedText("wake_mac_address", previous: value.wakeOnLAN.macAddress)
        value.wakeOnLAN.automaticallyWake = args.bool("automatically_wake") ?? value.wakeOnLAN.automaticallyWake
        guard !value.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.host.contains("\0"),
            value.environmentVariablesAreValid, value.terminalTransports.isValid, value.wakeOnLAN.isValid,
            !value.sshEnabled
                || HostLibraryModel.validatedRoute(for: value, lookup: { id in hosts.hosts.first { $0.id == id } })
                    != nil
        else { throw ResourceToolError.invalidInput }
        try await hosts.saveHost(value)
        guard let saved = hosts.hosts.first(where: { $0.id == id }) else { throw ResourceToolError.saveFailed }
        return ResourceToolOutput.host(saved, reusableIdentityIDs: identityIDs)
    }

    private func hostProxy(_ name: String, args: ResourceToolArguments, previous: HostProxy?) throws -> HostProxy? {
        if args.clears.contains(name) { return nil }
        guard let raw = args.values[name] else { return previous }
        let fields = try ResourceToolArguments(raw)
        let proxy = HostProxy(
            kind: try fields.enumValue("kind", default: HostProxy.ProtocolKind.http),
            hostname: fields.text("address") ?? "", port: fields.int("port") ?? 0,
            username: fields.text("username") ?? previous?.username ?? "",
            identityID: try fields.optionalID("identity_id") ?? previous?.identityID)
        guard proxy.isValid else { throw ResourceToolError.invalidInput }
        if let id = proxy.identityID,
            !credentials.managedIdentities.contains(where: { $0.id == id && $0.hasCredential })
        {
            throw ResourceToolError.invalidReference
        }
        return proxy
    }

    private func manageHostGroup(
        _ action: ResourceToolSpecification.Action, _ args: ResourceToolArguments, hosts: any AgentHostManaging
    ) throws -> AgentJSONValue {
        if action == .list { return .object(["host_groups": .array(hosts.groups.map(ResourceToolOutput.hostGroup))]) }
        let id = action == .add ? UUID() : try args.uuid("host_group_id")
        let original = hosts.groups.first { $0.id == id }
        guard action == .add || original != nil else { throw ResourceToolError.notFound }
        if action == .get { return ResourceToolOutput.hostGroup(original!) }
        if action == .delete {
            try hosts.deleteGroup(id, keepHosts: args.bool("keep_hosts") ?? true)
            return ResourceToolOutput.deleted(id)
        }
        var value = original ?? HostGroup(id: id, name: "")
        value.name = args.text("name") ?? value.name
        value.parentID = try args.updatedID("parent_id", previous: value.parentID)
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResourceToolError.invalidInput
        }
        var visited: Set<UUID> = [id]
        var cursor = value.parentID
        while let parentID = cursor {
            guard visited.insert(parentID).inserted else { throw ResourceToolError.invalidInput }
            guard let parent = hosts.groups.first(where: { $0.id == parentID }), parent.tailscale == nil else {
                throw ResourceToolError.invalidReference
            }
            cursor = parent.parentID
        }
        try hosts.saveGroup(value)
        return ResourceToolOutput.hostGroup(value)
    }
}

extension ResourceToolArguments {
    func updatedID(_ name: String, previous: UUID?) throws -> UUID? {
        clears.contains(name) ? nil : try optionalID(name) ?? previous
    }

    func clearedText(_ name: String, previous: String) -> String {
        clears.contains(name) ? "" : text(name) ?? previous
    }
}
