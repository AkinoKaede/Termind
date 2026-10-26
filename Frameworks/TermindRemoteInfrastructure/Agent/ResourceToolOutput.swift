// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

/// Explicit allowlists; never encode credential domain models or runtime connection objects.
nonisolated enum ResourceToolOutput {
    static func id(_ id: UUID?) -> AgentJSONValue { id.map { .string($0.uuidString) } ?? .null }
    static func strings(_ values: [String]) -> AgentJSONValue { .array(values.map(AgentJSONValue.string)) }
    static func deleted(_ value: UUID) -> AgentJSONValue { .object(["id": id(value), "deleted": .bool(true)]) }

    static func identity(_ value: AgentIdentityInfo) -> AgentJSONValue {
        .object([
            "id": id(value.id), "name": .string(value.name), "username": .string(value.username),
            "key_id": id(value.keyID), "storage": .string(value.storage.rawValue), "notes": .string(value.notes),
            "color": .string(value.color.rawValue), "credential_configured": .bool(value.hasCredential),
            "availability": .string(value.availability),
        ])
    }

    static func key(_ value: AgentKeyInfo) -> AgentJSONValue {
        .object([
            "id": id(value.id), "label": .string(value.label), "algorithm": .string(value.algorithm.rawValue),
            "public_key": .string(value.publicKey), "certificate": .string(value.certificate),
            "fingerprint": .string(value.fingerprint), "storage": .string(value.storage.rawValue),
            "bits": value.keySize.map { .number(Double($0)) } ?? .null, "encrypted": .bool(value.encrypted),
            "availability": .string(value.availability),
            "requires_user_presence": .bool(value.requiresUserPresence),
            "created_at": .string(value.createdAt.ISO8601Format()), "color": .string(value.color.rawValue),
        ])
    }

    static func snippet(_ value: Snippet, includeBody: Bool) -> AgentJSONValue {
        var fields: [String: AgentJSONValue] = [
            "id": id(value.id), "title": .string(value.title), "color": .string(value.colorTag.rawValue),
            "package_id": id(value.packageID), "target_host_ids": .array(value.targetHostIDs.map { id($0) }),
            "line_count": .number(Double(value.body.components(separatedBy: "\n").count)),
        ]
        if includeBody { fields["body"] = .string(value.body) }
        return .object(fields)
    }

    static func package(_ value: SnippetPackage) -> AgentJSONValue {
        .object(["id": id(value.id), "name": .string(value.name), "parent_id": id(value.parentID)])
    }

    static func forwarding(_ value: PortForwardingRule, status: AgentForwardingStatus) -> AgentJSONValue {
        .object([
            "id": id(value.id), "host_id": id(value.hostID), "kind": .string(value.kind.rawValue),
            "bind_host": .string(value.bindHost), "bind_port": .number(Double(value.bindPort)),
            "target_host": value.targetHost.map(AgentJSONValue.string) ?? .null,
            "target_port": value.targetPort.map { .number(Double($0)) } ?? .null,
            "label": .string(value.label), "color": .string(value.colorTag.rawValue),
            "status": .string(status.state), "requires_user_action": .bool(status.requiresUserAction),
        ])
    }

    static func metrics(_ value: AgentMetricsInfo) -> AgentJSONValue {
        let selection = value.selection
        return .object([
            "host_id": id(selection.id), "enabled": .bool(selection.enabled), "status": .string(value.state),
            "disks": selection.disks.map { strings($0.sorted()) } ?? .null,
            "interfaces": selection.interfaces.map { strings($0.sorted()) } ?? .null,
            "available_disks": strings(value.availableDisks),
            "available_interfaces": strings(value.availableInterfaces),
            "requires_user_action": .bool(value.state == "awaiting_authentication"),
        ])
    }
}
