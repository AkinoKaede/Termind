// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

extension ResourceToolCardPresentation {
    nonisolated struct Projection {
        let locale: Locale
        let names: [String: AgentJSONValue]

        func text(_ value: LocalizedStringResource) -> String { AppLocalization.resolve(value, locale: locale) }
        func label(_ key: String) -> String {
            text(AppStrings.ResourceCards.labels[key] ?? AppStrings.ResourceCards.resource)
        }
        func field(_ key: String, _ value: String) -> AgentToolDetail.Field { .init(label: label(key), value: value) }
        func reference(_ id: String?) -> String {
            guard let id, !id.isEmpty else { return text(AppStrings.ResourceCards.none) }
            return names[UUID(uuidString: id)?.uuidString ?? id]?.stringValue ?? String(id.prefix(8))
        }
        func status(_ raw: String) -> String {
            guard let value = AppStrings.ResourceCards.states[raw] else {
                return text(AppStrings.ResourceCards.unknown)
            }
            return text(value)
        }
        func value(_ value: AgentJSONValue) -> String {
            if let boolean = value.boolValue {
                return text(boolean ? AppStrings.ResourceCards.yes : AppStrings.ResourceCards.no)
            }
            if let number = value.numberValue { return number.formatted(.number.locale(locale)) }
            if let string = value.stringValue {
                if let localized = AppStrings.ResourceCards.states[string] { return text(localized) }
                return string
            }
            return ""
        }

        func project(_ object: [String: AgentJSONValue], resource: Resource) -> ResourceToolCardContent {
            var card = ResourceToolCardContent()
            func string(_ key: String) -> String? {
                guard let string = object[key]?.stringValue, !string.isEmpty else { return nil }
                return string
            }
            func add(_ key: String, detail: Bool = false) {
                guard let raw = object[key], raw != .null else { return }
                let rendered = value(raw)
                guard !rendered.isEmpty else { return }
                if detail {
                    card.details.append(field(key, rendered))
                } else {
                    card.fields.append(field(key, rendered))
                }
            }
            func relation(_ key: String, detail: Bool = false) {
                guard let id = string(key) else { return }
                let item = field(key, reference(id))
                if detail { card.details.append(item) } else { card.fields.append(item) }
                if names[id] == nil { card.details.append(field(key, id)) }
            }
            func block(_ key: String, lines: Int = 2, expandedOnly: Bool = false, mono: Bool = false) {
                guard let content = string(key) else { return }
                card.blocks.append(
                    .init(
                        title: label(key), text: content, monospaced: mono,
                        previewLines: lines, expandedOnly: expandedOnly))
            }
            card.title =
                string("display_name") ?? string("name") ?? string("label") ?? string("title")
                ?? reference(string("id") ?? string("host_id"))
            if let id = string("id") ?? string("host_id"), names[id] == nil,
                card.title == reference(id)
            {
                card.details.append(field("resource", id))
            }
            switch resource {
            case .host:
                block("address", mono: true)
                let protocols =
                    object["protocols"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
                    ?? [
                        object["ssh_enabled"]?.boolValue == true ? "SSH" : nil,
                        object["telnet_enabled"]?.boolValue == true ? "Telnet" : nil,
                    ].compactMap { $0 }
                if !protocols.isEmpty { card.fields.append(field("protocols", protocols.joined(separator: " / "))) }
                if let path = string("group_path") {
                    card.fields.append(field("group_id", path))
                } else {
                    relation("group_id")
                }
                for key in ["ssh_identity_id", "telnet_identity_id", "jump_host_id", "startup_snippet_id"] {
                    relation(key, detail: true)
                }
                for key in ["ssh_port", "telnet_port"] {
                    if object[key == "ssh_port" ? "ssh_enabled" : "telnet_enabled"]?.boolValue == true {
                        add(key, detail: true)
                    }
                }
                if let state = string("connection_state") { card.fields.append(field("status", status(state))) }
                for key in ["proxy", "telnet_proxy"] {
                    if let proxy = object[key]?.objectValue {
                        card.details.append(field(key, endpoint(proxy, host: "address", port: "port")))
                    }
                }
            case .hostGroup, .package:
                relation("parent_id")
            case .identity:
                add("username")
                relation("key_id")
                if let state = string("availability") { card.fields.append(field("availability", status(state))) }
                add("storage", detail: true)
                block("notes")
            case .key:
                let algorithm = Self.algorithms[string("algorithm") ?? ""] ?? text(AppStrings.ResourceCards.unknown)
                let bits = object["bits"].map(value) ?? ""
                card.fields.append(
                    field("algorithm", [algorithm, bits].filter { !$0.isEmpty }.joined(separator: " · ")))
                add("storage")
                if let state = string("availability") { card.fields.append(field("availability", status(state))) }
                if let fingerprint = string("fingerprint") {
                    card.fields.append(
                        field("fingerprint", String(fingerprint.prefix(24)) + (fingerprint.count > 24 ? "…" : "")))
                }
                block("fingerprint", expandedOnly: true, mono: true)
                for key in ["encrypted", "requires_user_presence"] { add(key, detail: true) }
                block("public_key", expandedOnly: true, mono: true)
                block("certificate", expandedOnly: true, mono: true)
            case .forwarding:
                add("kind")
                relation("host_id")
                let bind = endpoint(object, host: "bind_host", port: "bind_port")
                if string("kind") == "dynamic" {
                    card.route = [field("socks_listener", bind)]
                } else {
                    card.route = [
                        field("listener", bind),
                        field("destination", endpoint(object, host: "target_host", port: "target_port")),
                    ]
                }
                if let state = string("status") { card.fields.append(field("status", status(state))) }
            case .snippet:
                relation("package_id")
                if let body = string("body") {
                    card.fields.append(
                        field(
                            "body", text(AppStrings.ResourceCards.lineCount(body.components(separatedBy: "\n").count))))
                } else if let raw = object["line_count"]?.numberValue, let lines = Int(exactly: raw), lines >= 0 {
                    card.fields.append(field("body", text(AppStrings.ResourceCards.lineCount(lines))))
                }
                if let targets = object["target_host_ids"]?.arrayValue {
                    card.fields.append(
                        field("target_host_ids", text(AppStrings.ResourceCards.targetCount(targets.count))))
                    if !targets.isEmpty {
                        card.blocks.append(
                            .init(
                                title: label("target_host_ids"),
                                text: targets.compactMap(\.stringValue).map { names[$0]?.stringValue ?? $0 }.joined(
                                    separator: "\n"),
                                monospaced: false, previewLines: 2, expandedOnly: true))
                    }
                }
                block("body", lines: 6, mono: true)
            case .metrics:
                if string("display_name") == nil { card.title = reference(string("host_id")) }
                add("enabled")
                if let state = string("status") { card.fields.append(field("status", status(state))) }
                for key in ["disks", "interfaces"] where object[key] != nil {
                    let devices = object[key]?.arrayValue?.compactMap(\.stringValue)
                    card.fields.append(
                        field(
                            key,
                            devices.map {
                                $0.isEmpty
                                    ? text(AppStrings.ResourceCards.noDevices)
                                    : text(AppStrings.ResourceCards.deviceCount($0.count))
                            } ?? text(AppStrings.ResourceCards.allDevices)))
                    if let devices, !devices.isEmpty {
                        card.blocks.append(
                            .init(
                                title: label(key), text: devices.joined(separator: "\n"),
                                monospaced: false, previewLines: 2, expandedOnly: true))
                    }
                }
                if let overview = object["overview"]?.objectValue {
                    for key in ["cpu_percent", "memory_percent"] {
                        let number =
                            overview[key]?.numberValue.map { String(format: "%.1f%%", locale: locale, $0) } ?? "—"
                        card.measurements.append(field(key, number))
                    }
                    if let date = overview["sampled_at"]?.stringValue {
                        let parsed = ISO8601DateFormatter().date(from: date)
                        card.fields.append(field("sampled_at", parsed?.formatted(.dateTime.locale(locale)) ?? date))
                    }
                    if let swap = overview["swap_percent"]?.numberValue,
                        (overview["swap_total_bytes"]?.numberValue ?? 0) > 0
                    {
                        card.details.append(field("swap_percent", String(format: "%.1f%%", locale: locale, swap)))
                    }
                    if overview["stale"]?.boolValue == true {
                        card.notices.append(.message(text(AppStrings.ResourceCards.stale), .warning))
                    }
                }
            }
            if object["requires_user_action"]?.boolValue == true
                || ["awaiting_authentication", "awaiting_trust"].contains(string("status") ?? "")
            {
                card.notices.append(.message(text(AppStrings.ResourceCards.authenticationRequired), .warning))
            }
            return card
        }

        func endpoint(_ object: [String: AgentJSONValue], host: String, port: String) -> String {
            let address = object[host]?.stringValue ?? "—"
            let formatted = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
            guard let raw = object[port]?.numberValue, let number = Int(exactly: raw),
                (1...65_535).contains(number)
            else { return formatted }
            return "\(formatted):\(number)"
        }

        func unavailable() -> ResourceToolCardContent {
            var card = ResourceToolCardContent()
            card.notices = [.message(text(AppStrings.ResourceCards.unavailable), .secondary)]
            return card
        }

        private static let algorithms = [
            "ssh-ed25519": "Ed25519", "ed25519": "Ed25519", "ssh-rsa": "RSA", "rsa": "RSA",
            "ecdsa-sha2-nistp256": "ECDSA P-256", "ecdsa-sha2-nistp384": "ECDSA P-384",
            "ecdsa-sha2-nistp521": "ECDSA P-521", "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK P-256",
        ]

        func failure(_ value: AgentJSONValue?, raw: String, state: AgentToolCard.State) -> ResourceToolCardContent {
            var card = ResourceToolCardContent()
            // Errors can contain parser input in older histories. Never render arbitrary error payloads.
            let message =
                value?.objectValue?["error"]?.stringValue ?? value?.objectValue?["message"]?.stringValue
                ?? value?.stringValue ?? raw
            var copy = AppStrings.ResourceCards.failures[message] ?? AppStrings.ResourceCards.failed
            if state == .denied { copy = AppStrings.ResourceCards.denied }
            if state == .interrupted { copy = AppStrings.ResourceCards.cancelled }
            card.notices = [
                .message(text(copy), .failure)
            ]
            return card
        }

        func arguments(_ args: [String: AgentJSONValue], resource: Resource, deleting: Bool) -> [AgentToolDetail.Item] {
            var items: [AgentToolDetail.Item] = []
            for key in AppStrings.ResourceCards.argumentOrder {
                guard let raw = args[key], raw != .null else { continue }
                if key.hasSuffix("_secret_handle") {
                    items.append(.field(field(key, text(AppStrings.ResourceCards.newCredential))))
                } else if key == "public_key" || key == "certificate" {
                    // The material has not been validated yet; a mistaken paste must not expose a private key.
                    if raw.stringValue?.isEmpty == false {
                        items.append(.field(field(key, text(AppStrings.ResourceCards.provided))))
                    }
                } else if key == "body" || key == "notes" {
                    if let string = raw.stringValue, !string.isEmpty {
                        items.append(
                            .text(
                                .init(
                                    title: label(key), text: string,
                                    style: key == "notes" ? .plain : .monospaced, isCollapsible: false)))
                    }
                } else if key == "clear_fields" {
                    for name in raw.arrayValue?.compactMap(\.stringValue) ?? [] {
                        guard AppStrings.ResourceCards.labels[name] != nil else { continue }
                        items.append(
                            .field(
                                field(
                                    name,
                                    text(
                                        name == "disks" || name == "interfaces"
                                            ? AppStrings.ResourceCards.allDevices : AppStrings.ResourceCards.clear))))
                    }
                } else if key == "proxy" || key == "telnet_proxy" {
                    if let proxy = raw.objectValue {
                        items.append(
                            .text(
                                .init(
                                    title: label(key), text: endpoint(proxy, host: "address", port: "port"),
                                    style: .monospaced)))
                        for nested in ["kind", "username", "identity_id"] {
                            if let value = proxy[nested], value != .null {
                                items.append(
                                    .field(
                                        .init(
                                            label: label(key) + " · " + label(nested),
                                            value: value.stringValue.map {
                                                nested == "identity_id" ? reference($0) : $0
                                            } ?? "")))
                            }
                        }
                    }
                } else if key == "environment_variables" {
                    let variables =
                        raw.arrayValue?.compactMap { entry -> String? in
                            guard let object = entry.objectValue, let name = object["variable"]?.stringValue else {
                                return nil
                            }
                            return name + "=" + (object["value"]?.stringValue ?? "")
                        } ?? []
                    items.append(
                        .text(.init(title: label(key), text: variables.joined(separator: "\n"), style: .monospaced)))
                } else if let array = raw.arrayValue {
                    let values = array.compactMap(\.stringValue)
                    let content =
                        values.isEmpty
                        ? text(
                            key == "disks" || key == "interfaces"
                                ? AppStrings.ResourceCards.noDevices : AppStrings.ResourceCards.none)
                        : values.map { key == "target_host_ids" ? names[$0]?.stringValue ?? $0 : $0 }.joined(
                            separator: "\n")
                    items.append(.text(.init(title: label(key), text: content, style: .plain)))
                } else if key.hasSuffix("_id"), let id = raw.stringValue {
                    items.append(.field(field(key, reference(id))))
                    if names[UUID(uuidString: id)?.uuidString ?? id] == nil {
                        items.append(.text(.init(title: label(key), text: id, style: .monospaced)))
                    }
                } else {
                    let rendered = value(raw)
                    if !rendered.isEmpty { items.append(.field(field(key, rendered))) }
                }
            }
            if deleting && (resource == .package || resource == .hostGroup) {
                let keep = args[resource == .package ? "keep_snippets" : "keep_hosts"]?.boolValue ?? true
                items.append(
                    .message(
                        text(keep ? AppStrings.ResourceCards.keepContents : AppStrings.ResourceCards.deleteContents),
                        keep ? .secondary : .warning))
            }
            if items.isEmpty { items = [.message(text(AppStrings.ResourceCards.noChanges), .secondary)] }
            return items
        }
    }
}
