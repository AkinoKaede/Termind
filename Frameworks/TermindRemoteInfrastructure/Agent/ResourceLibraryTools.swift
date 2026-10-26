// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

extension AgentResourceManager {
    func manageSnippet(_ spec: ResourceToolSpecification, _ args: ResourceToolArguments) throws -> AgentJSONValue {
        let isPackage = spec.resource == .snippetPackage
        if spec.action == .list {
            return isPackage
                ? .object(["snippet_packages": .array(snippets.snippetPackages.map(ResourceToolOutput.package))])
                : .object([
                    "snippets": .array(snippets.snippets.map { ResourceToolOutput.snippet($0, includeBody: false) })
                ])
        }
        let id = spec.action == .add ? UUID() : try args.uuid(spec.resource.idField)
        if isPackage {
            let original = snippets.snippetPackages.first { $0.id == id }
            guard spec.action == .add || original != nil else { throw ResourceToolError.notFound }
            if spec.action == .get { return ResourceToolOutput.package(original!) }
            if spec.action == .delete {
                try snippets.removePackage(id, keepSnippets: args.bool("keep_snippets") ?? true)
                return ResourceToolOutput.deleted(id)
            }
            var value = original ?? SnippetPackage(id: id, name: "")
            value.name = args.text("name") ?? value.name
            value.parentID =
                args.clears.contains("parent_id") ? nil : try args.optionalID("parent_id") ?? value.parentID
            guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ResourceToolError.invalidInput
            }
            var visited: Set<UUID> = [id]
            var cursor = value.parentID
            while let parentID = cursor {
                guard visited.insert(parentID).inserted else { throw ResourceToolError.invalidInput }
                guard let parent = snippets.snippetPackages.first(where: { $0.id == parentID }) else {
                    throw ResourceToolError.invalidReference
                }
                cursor = parent.parentID
            }
            try snippets.save(value)
            return ResourceToolOutput.package(value)
        }
        let original = snippets.snippets.first { $0.id == id }
        guard spec.action == .add || original != nil else { throw ResourceToolError.notFound }
        if spec.action == .get { return ResourceToolOutput.snippet(original!, includeBody: true) }
        if spec.action == .delete {
            try snippets.removeSnippet(id)
            return ResourceToolOutput.deleted(id)
        }
        var value = original ?? Snippet(id: id, title: "", body: "")
        value.title = args.text("title") ?? value.title
        value.body = args.text("body") ?? value.body
        value.colorTag = try args.enumValue("color", default: value.colorTag)
        value.packageID =
            args.clears.contains("package_id") ? nil : try args.optionalID("package_id") ?? value.packageID
        if let packageID = value.packageID, !snippets.snippetPackages.contains(where: { $0.id == packageID }) {
            throw ResourceToolError.invalidReference
        }
        if let rawIDs = args.strings("target_host_ids") {
            let ids = rawIDs.compactMap(UUID.init(uuidString:))
            guard ids.count == rawIDs.count, ids.allSatisfy(snippets.containsHost) else {
                throw ResourceToolError.invalidReference
            }
            var seen: Set<UUID> = []
            value.targetHostIDs = ids.filter { seen.insert($0).inserted }
        } else if args.clears.contains("target_host_ids") {
            value.targetHostIDs = []
        }
        guard !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.body.contains("\0")
        else { throw ResourceToolError.invalidInput }
        try snippets.save(value)
        return ResourceToolOutput.snippet(value, includeBody: true)
    }

    func manageForwarding(_ action: ResourceToolSpecification.Action, _ args: ResourceToolArguments) throws
        -> AgentJSONValue
    {
        func output(_ rule: PortForwardingRule) -> AgentJSONValue {
            ResourceToolOutput.forwarding(rule, status: forwardingRuntime.managementStatus(rule.id))
        }
        if action == .list { return .object(["port_forwardings": .array(forwardings.rules.map(output))]) }
        let id = action == .add ? UUID() : try args.uuid("port_forwarding_id")
        let original = forwardings.rules.first { $0.id == id }
        guard action == .add || original != nil else { throw ResourceToolError.notFound }
        if action == .get { return output(original!) }
        if action == .delete {
            try forwardings.delete(id)
            return ResourceToolOutput.deleted(id)
        }
        if action == .start || action == .stop {
            if action == .start {
                try forwardings.requireStart(id)
                forwardingRuntime.start(id)
            } else {
                forwardingRuntime.stop(id)
            }
            return output(original!)
        }
        var value = try original ?? PortForwardingRule(id: id, hostID: args.uuid("host_id"))
        value.hostID = try args.optionalID("host_id") ?? value.hostID
        value.kind = try args.enumValue("kind", default: value.kind)
        value.bindHost = args.text("bind_host") ?? value.bindHost
        value.bindPort = args.int("bind_port") ?? value.bindPort
        value.targetHost = args.text("target_host") ?? value.targetHost
        value.targetPort = args.int("target_port") ?? value.targetPort
        value.label = args.text("label") ?? value.label
        value.colorTag = try args.enumValue("color", default: value.colorTag)
        guard let normalized = PortForwardingEditorPolicy.normalized(value) else {
            throw ResourceToolError.invalidInput
        }
        return output(try forwardings.save(normalized))
    }

    func manageMetrics(_ action: ResourceToolSpecification.Action, _ args: ResourceToolArguments) throws
        -> AgentJSONValue
    {
        if action == .list {
            return .object(["metrics": .array(metrics.managedMetrics.map(ResourceToolOutput.metrics))])
        }
        let id = try args.uuid("host_id")
        let original = metrics.managedMetrics.first { $0.selection.id == id }
        guard action == .add || original != nil else { throw ResourceToolError.notFound }
        if action == .add, original != nil { throw ResourceToolError.invalidInput }
        if action == .delete {
            try metrics.removeSelection(id)
            return ResourceToolOutput.deleted(id)
        }
        var requested: Bool?
        if action == .refresh {
            requested = metrics.requestRefresh(id)
        } else {
            var selection = original?.selection ?? MetricsSelection(id: id)
            selection.enabled = args.bool("enabled") ?? selection.enabled
            if action == .start { selection.enabled = true }
            if action == .stop { selection.enabled = false }
            if let devices = args.strings("disks") { selection.disks = Set(devices) }
            if let devices = args.strings("interfaces") { selection.interfaces = Set(devices) }
            if args.clears.contains("disks") { selection.disks = nil }
            if args.clears.contains("interfaces") { selection.interfaces = nil }
            try metrics.saveSelection(selection)
        }
        guard let saved = metrics.managedMetrics.first(where: { $0.selection.id == id }) else {
            throw ResourceToolError.saveFailed
        }
        var result = ResourceToolOutput.metrics(saved).objectValue ?? [:]
        if let requested { result["refresh_requested"] = .bool(requested) }
        return .object(result)
    }
}
