// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AppKit
import Foundation
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@Suite
struct ResourceToolCardTests {
    private let english = Locale(identifier: "en")

    @Test func keyMaterialIsOptInAndSecretsNeverEnterTheCard() throws {
        let publicKey = "ssh-ed25519 " + String(repeating: "PUBLIC", count: 1_000)
        let certificate = "ssh-ed25519-cert-v01@openssh.com " + String(repeating: "CERT", count: 1_000)
        let card = makeCard(
            TermindToolName.getKey,
            result: [
                "label": .string("Deploy"), "algorithm": .string("ed25519"), "storage": .string("thisDevice"),
                "fingerprint": .string("SHA256:" + String(repeating: "a", count: 43)),
                "availability": .string("available"),
                "public_key": .string(publicKey), "certificate": .string(certificate),
                "private_key": .string("TEST-PRIVATE"), "passphrase": .string("TEST-PASSPHRASE"),
                "private_key_secret_handle": .string("TEST-HANDLE"), "credential_ref": .string("TEST-REFERENCE"),
            ])
        let content = try #require(ResourceToolCardPresentation.content(for: card, locale: english))
        #expect(content.title == "Deploy")
        #expect(content.fields.count == 4)
        #expect(content.fields.allSatisfy { $0.value.count < 40 })
        #expect(content.blocks.allSatisfy { $0.expandedOnly })
        #expect(content.blocks.contains { $0.text == publicKey })
        #expect(content.blocks.contains { $0.text == certificate })
        let text = AgentToolDetailPreview(content.detail).fullText
        for secret in ["TEST-PRIVATE", "TEST-PASSPHRASE", "TEST-HANDLE", "TEST-REFERENCE"] {
            #expect(!text.contains(secret))
        }
        var replay = card
        replay.result = try JSONDecoder().decode(AgentToolResult.self, from: JSONEncoder().encode(card.result!))
        #expect(ResourceToolCardPresentation.content(for: replay, locale: english) == content)
        let fallback = try #require(TermindToolPresentationProfiles.renderer.detail(for: replay, locale: english))
        #expect(!AgentToolDetailPreview(fallback).fullText.contains("TEST-PRIVATE"))
    }

    @Test func approvalProjectsOnlyChangesAndSummarizesUnvalidatedPublicMaterial() throws {
        let id = UUID().uuidString
        let arguments: [String: AgentJSONValue] = [
            "key_id": .string(id), "label": .null, "storage": .null,
            "private_key_secret_handle": .string("ONCE-ONLY-HANDLE"),
            "passphrase_secret_handle": .string("ANOTHER-HANDLE"),
            "public_key": .string("public-material"), "certificate": .string("certificate-material"),
            "private_key": .string("FORBIDDEN-PLAINTEXT"),
            "clear_fields": .array([.string("passphrase")]),
        ]
        let card = makeCard(TermindToolName.editKey, result: [:], arguments: arguments, action: .edit)
        let request = AgentApprovalRequest(
            invocation: card.invocation, descriptor: card.descriptor, userIntent: "Rotate")
        let approval = TermindToolPresentationProfiles.renderer.approval(
            for: request, resourceNames: [id: .string("Deploy key")], locale: english)
        let text = AgentToolDetailPreview(approval.detail).fullText
        #expect(text.contains("Deploy key"))
        #expect(text.contains("New credential provided"))
        #expect(text.contains("Clear"))
        #expect(!text.contains("public-material"))
        #expect(!text.contains("certificate-material"))
        #expect(!text.contains("Storage"))
        #expect(!text.contains("ONCE-ONLY-HANDLE"))
        #expect(!text.contains("ANOTHER-HANDLE"))
        #expect(!text.contains("FORBIDDEN-PLAINTEXT"))
        #expect(
            approval.detail.items.contains {
                if case .field(let field) = $0 { return field.label == "Public Key" && field.value == "Provided" }
                return false
            })
    }

    @Test func forwardingKeepsIPv6AndDynamicListenerSemantics() throws {
        var fields: [String: AgentJSONValue] = [
            "label": .string("Database"), "kind": .string("local"), "bind_host": .string("::1"),
            "bind_port": .number(5432), "target_host": .string("2001:db8::2"), "target_port": .number(5433),
            "status": .string("awaiting_authentication"), "requires_user_action": .bool(true),
        ]
        let content = try #require(
            ResourceToolCardPresentation.content(
                for: makeCard(TermindToolName.startPortForwarding, result: fields), locale: english))
        #expect(content.route.map(\.value) == ["[::1]:5432", "[2001:db8::2]:5433"])
        #expect(AgentToolDetailPreview(content.detail).fullText.contains("Start requested"))
        #expect(AgentToolDetailPreview(content.detail).fullText.contains("Complete authentication"))
        fields["kind"] = .string("dynamic")
        let dynamic = try #require(
            ResourceToolCardPresentation.content(
                for: makeCard(TermindToolName.getPortForwarding, result: fields), locale: english))
        #expect(dynamic.route.count == 1)
        #expect(dynamic.route.first?.label == "SOCKS Listener")
        #expect(!AgentToolDetailPreview(dynamic.detail).fullText.contains("2001:db8::2"))
    }

    @Test func metricsDistinguishesAllFromNoneAndDoesNotClaimFreshSamples() throws {
        let card = makeCard(
            TermindToolName.refreshMetrics,
            result: [
                "host_id": .string(UUID().uuidString), "disks": .null, "interfaces": .array([]),
                "status": .string("sleeping"), "refresh_requested": .bool(false),
            ])
        let content = try #require(ResourceToolCardPresentation.content(for: card, locale: english))
        let text = AgentToolDetailPreview(content.detail).fullText
        #expect(text.contains("All devices"))
        #expect(text.contains("No devices selected"))
        #expect(text.contains("Sleeping"))
        #expect(text.contains("Refresh not requested"))
        let sample = makeCard(
            TermindToolName.getMetrics,
            result: [
                "display_name": .string("Server"), "status": .string("live"),
                "overview": .object([
                    "cpu_percent": .number(24), "memory_percent": .number(62),
                    "sampled_at": .string("2026-10-26T01:00:00Z"), "stale": .bool(true),
                ]),
                "processes": .array([.object(["command": .string("UNNECESSARY-PROCESS")])]),
            ])
        let metrics = try #require(ResourceToolCardPresentation.content(for: sample, locale: english))
        #expect(metrics.measurements.map(\.value) == ["24.0%", "62.0%"])
        #expect(!AgentToolDetailPreview(metrics.detail).fullText.contains("UNNECESSARY-PROCESS"))
        #expect(AgentToolDetailPreview(metrics.detail).fullText.contains("Cached metrics are stale"))
    }

    @Test func resourceListsAreTwoLineSummariesWithoutBodies() throws {
        for (name, key) in [
            (TermindToolName.listHosts, "hosts"), (TermindToolName.listHostGroups, "host_groups"),
            (TermindToolName.listIdentities, "identities"), (TermindToolName.listKeys, "keys"),
            (TermindToolName.listSnippets, "snippets"), (TermindToolName.listSnippetPackages, "snippet_packages"),
            (TermindToolName.listPortForwardings, "port_forwardings"), (TermindToolName.listMetrics, "metrics"),
        ] {
            let rows: [AgentJSONValue] = (0..<20).map { index in
                .object([
                    "name": .string("Item \(index)"), "display_name": .string("Item \(index)"),
                    "body": .string("SCRIPT-BODY"),
                    "public_key": .string("PUBLIC-MATERIAL"), "private_key": .string("PRIVATE-MATERIAL"),
                    "certificate": .string("CERT-MATERIAL"), "address": .string("test.invalid"),
                ])
            }
            let content = try #require(
                ResourceToolCardPresentation.content(
                    for: makeCard(name, result: [key: .array(rows)]), locale: english))
            #expect(content.isList)
            #expect(content.rows.count == 20)
            #expect(content.visibleRows(expanded: false).count == 5)
            #expect(content.visibleRows(expanded: false).last?.title == "Item 4")
            #expect(content.visibleRows(expanded: true).last?.title == "Item 19")
            #expect(content.canExpand)
            #expect(content.blocks.isEmpty)
            let text = AgentToolDetailPreview(content.detail).fullText
            for forbidden in ["SCRIPT-BODY", "PUBLIC-MATERIAL", "PRIVATE-MATERIAL", "CERT-MATERIAL"] {
                #expect(!text.contains(forbidden))
            }
            let empty = try #require(
                ResourceToolCardPresentation.content(
                    for: makeCard(name, result: [key: .array([])]), locale: english))
            #expect(AgentToolDetailPreview(empty.detail).fullText.contains("No resources found"))
        }
    }

    @Test func malformedAndFailedHistoryCannotFallBackToRawSecretData() throws {
        var card = makeCard(TermindToolName.getIdentity, result: [:])
        for raw in ["ERROR SECRET-INPUT", "{\"error\":\"SECRET-INPUT\"}", "[]"] {
            card.result = .init(callID: "call", content: raw, isError: true)
            let detail = try #require(TermindToolPresentationProfiles.renderer.detail(for: card, locale: english))
            #expect(!AgentToolDetailPreview(detail).fullText.contains("SECRET-INPUT"))
            #expect(AgentToolDetailPreview(detail).fullText.contains("failed"))
        }
        card.result = .init(callID: "call", content: "SECRET-INPUT")
        let detail = try #require(TermindToolPresentationProfiles.renderer.detail(for: card, locale: english))
        #expect(AgentToolDetailPreview(detail).fullText == "Resource details are unavailable.")
        card.descriptor.target = .mcp
        #expect(ResourceToolCardPresentation.content(for: card, locale: english) == nil)
    }

    @Test func groupDeletionWarnsOnlyWhenContentsAreExplicitlyDeleted() {
        for keep in [true, false] {
            let card = makeCard(
                TermindToolName.deleteSnippetPackage, result: [:],
                arguments: ["snippet_package_id": .string(UUID().uuidString), "keep_snippets": .bool(keep)],
                action: .delete)
            let request = AgentApprovalRequest(
                invocation: card.invocation, descriptor: card.descriptor, userIntent: "Delete")
            let detail = TermindToolPresentationProfiles.renderer.approval(for: request, locale: english).detail
            #expect(
                detail.items.contains {
                    if case .message(_, let tint) = $0 { return tint == (keep ? .secondary : .warning) }
                    return false
                })
        }
    }

    @Test func snippetBodyIsPreservedBehindSixLinePreview() throws {
        let script = (0..<40).map { "echo \($0)" }.joined(separator: "\n")
        let content = try #require(
            ResourceToolCardPresentation.content(
                for: makeCard(
                    TermindToolName.getSnippet, result: ["title": .string("Deploy"), "body": .string(script)]),
                locale: english))
        #expect(content.blocks.first?.previewLines == 6)
        #expect(content.blocks.first?.text == script)
        #expect(content.canExpand)
    }

    @Test @MainActor func nativeFieldsStackWhenTheirActualContentDoesNotFit() {
        let stack = NativeResourceAdaptiveStack()
        stack.addResourceView(NSTextField(labelWithString: "Source"), width: 100)
        stack.addResourceView(NSTextField(labelWithString: "Destination"), width: 200)
        stack.frame = NSRect(x: 0, y: 0, width: 600, height: 60)
        stack.layout()
        #expect(stack.orientation == .horizontal)
        stack.frame.size.width = 240
        stack.layout()
        #expect(stack.orientation == .vertical)
        let long = NativeResourceAdaptiveStack(forceVertical: true)
        long.addResourceView(NSTextField(labelWithString: "Public Key"), width: 200)
        long.frame = NSRect(x: 0, y: 0, width: 1_000, height: 60)
        long.layout()
        #expect(long.orientation == .vertical)
    }

    private func makeCard(
        _ name: String, result: [String: AgentJSONValue], arguments: [String: AgentJSONValue] = [:],
        action: AgentToolDescriptor.Presentation.ActionKind = .read
    ) -> AgentToolCard {
        .init(
            invocation: .init(runID: UUID(), call: .init(id: "call", name: name, arguments: .object(arguments))),
            descriptor: .init(
                name: name, summary: name, inputSchema: .object([:]), target: .local,
                approvalPolicy: .ask,
                presentation: .init(
                    symbol: "key", activity: .semanticLabel(.keys),
                    actionKind: action)),
            state: .completed, result: .init(callID: "call", content: AgentJSONValue.object(result).encodedString))
    }
}
