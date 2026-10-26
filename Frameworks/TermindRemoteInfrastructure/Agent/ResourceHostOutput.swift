// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindDomain

import struct TermindDomain.Host

extension ResourceToolOutput {
    static func host(_ value: Host, reusableIdentityIDs: Set<UUID>) -> AgentJSONValue {
        func identity(_ value: UUID?) -> AgentJSONValue {
            id(value.flatMap { reusableIdentityIDs.contains($0) ? $0 : nil })
        }
        func proxy(_ value: HostProxy?) -> AgentJSONValue {
            guard let value else { return .null }
            return .object([
                "kind": .string(value.kind.rawValue), "address": .string(value.hostname),
                "port": .number(Double(value.port)), "username": .string(value.username),
                "identity_id": identity(value.identityID),
            ])
        }
        return .object([
            "id": id(value.id), "name": .string(value.name), "address": .string(value.host),
            "group_id": id(value.groupID), "tags": strings(value.tags), "color": .string(value.colorTag.rawValue),
            "tailscale_managed": .bool(value.isTailscaleManaged),
            "ssh_enabled": .bool(value.sshEnabled), "ssh_port": .number(Double(value.sshPort)),
            "ssh_identity_id": identity(value.sshIdentityID), "ssh_charset": .string(value.sshCharset.rawValue),
            "telnet_enabled": .bool(value.telnetEnabled), "telnet_port": .number(Double(value.telnetPort)),
            "telnet_identity_id": identity(value.telnetIdentityID),
            "telnet_charset": .string(value.telnetCharset.rawValue),
            "jump_host_id": id(value.jumpHostID), "proxy": proxy(value.proxy), "telnet_proxy": proxy(value.telnetProxy),
            "startup_snippet_id": id(value.startupSnippetID),
            "sftp_initial_path": .string(value.sftpChannelInitialPath),
            "icon_override_id": value.iconOverrideID.map(AgentJSONValue.string) ?? .null,
            "shell_integration": .string(value.shellIntegrationMode.rawValue),
            "agent_forwarding_enabled": .bool(value.agentForwardingEnabled),
            "forwarding_max_connections": .number(Double(value.portForwardingMaxConnections)),
            "environment_variables": .array(
                value.environmentVariables.map {
                    .object(["variable": .string($0.variable), "value": .string($0.value)])
                }),
            "mosh_enabled": .bool(value.terminalTransports.moshEnabled),
            "mosh_udp_port_range": .string(value.terminalTransports.moshUDPPortRange),
            "eternal_terminal_enabled": .bool(value.terminalTransports.eternalTerminalEnabled),
            "eternal_terminal_port": .number(Double(value.terminalTransports.eternalTerminalPort)),
            "default_transport": .string(value.terminalTransports.defaultTransport.rawValue),
            "session_persistence_enabled": .bool(value.sessionPersistence.enabled),
            "session_backend": .string(value.sessionPersistence.backend.rawValue),
            "session_on_connect": .string(value.sessionPersistence.onConnect.rawValue),
            "wake_mac_address": .string(value.wakeOnLAN.macAddress),
            "automatically_wake": .bool(value.wakeOnLAN.automaticallyWake),
        ])
    }

    static func hostGroup(_ value: HostGroup) -> AgentJSONValue {
        .object([
            "id": id(value.id), "name": .string(value.name), "parent_id": id(value.parentID),
            "tailscale_managed": .bool(value.tailscale != nil),
        ])
    }
}
