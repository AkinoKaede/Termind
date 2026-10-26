// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

extension AgentResourceManager {
    /// Retain only names of referenced public resources, including the name of a deleted record.
    /// No credential resolution or secret-storage reference is involved.
    public func presentationNames(in value: AgentJSONValue) -> [String: AgentJSONValue] {
        var ids = Set<UUID>()
        func collect(_ value: AgentJSONValue, key: String = "") {
            if let object = value.objectValue {
                for (key, value) in object { collect(value, key: key) }
            } else if let array = value.arrayValue {
                for value in array { collect(value, key: key) }
            } else if key == "id" || key.hasSuffix("_id") || key == "target_host_ids",
                let raw = value.stringValue, let id = UUID(uuidString: raw)
            {
                ids.insert(id)
            }
        }
        collect(value)
        var names: [String: AgentJSONValue] = [:]
        func include(_ id: UUID, _ name: String) {
            if ids.contains(id), !name.isEmpty { names[id.uuidString] = .string(name) }
        }
        for host in hosts?.hosts ?? [] { include(host.id, host.name.isEmpty ? host.host : host.name) }
        for group in hosts?.groups ?? [] { include(group.id, group.name) }
        for identity in credentials.managedIdentities { include(identity.id, identity.name) }
        for key in credentials.managedKeys { include(key.id, key.label) }
        for snippet in snippets.snippets { include(snippet.id, snippet.title) }
        for package in snippets.snippetPackages { include(package.id, package.name) }
        for rule in forwardings.rules { include(rule.id, rule.label) }
        return names
    }
}
