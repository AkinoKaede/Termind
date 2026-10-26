// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct ResourceToolPresentationTests {
    private let english = Locale(identifier: "en")
    private let renderer = TermindToolPresentationProfiles.renderer
    private let descriptors: [String: AgentToolDescriptor]

    init() {
        let library = HostLibraryModel(secrets: InMemorySecretStore())
        let metrics = ServerMetricsModel(
            hosts: library, preferences: EmptyMetricsPreferences(),
            makeSampler: { preconditionFailure("Presentation tests must not connect") })
        let manager = AgentResourceManager(
            credentials: CredentialLibraryModel(library: library), snippets: SnippetLibraryModel(library: library),
            forwardings: ForwardingLibraryModel(library: library), forwardingRuntime: UnusedForwardingRuntime(),
            metrics: metrics, hosts: AgentHostLibrary(library: library))
        let connections = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in throw AgentToolError.invalidHost },
            openConnection: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost }, sweepInterval: nil)
        descriptors = Dictionary(
            TermindAgentTools.tools(
                in: .init(
                    hosts: AgentHostResolver(store: library), metrics: metrics,
                    connections: connections, management: manager)
            ).map { ($0.descriptor.name, $0.descriptor) },
            uniquingKeysWith: { first, _ in first })
    }

    @Test(arguments: ResourceToolSpecification.all + [.init(resource: .host, action: .list)])
    func registeredResourceActionsUseGrammaticalNounsInEveryState(_ specification: ResourceToolSpecification) throws {
        let name =
            specification.resource == .host && specification.action == .list
            ? TermindToolName.listHosts : specification.name
        let nouns: (single: String, plural: String) =
            switch specification.resource {
            case .host: ("a host", "hosts")
            case .hostGroup: ("a host group", "host groups")
            case .identity: ("an identity", "identities")
            case .key: ("a key", "keys")
            case .snippet: ("a snippet", "snippets")
            case .snippetPackage: ("a snippet package", "snippet packages")
            case .portForwarding: ("a port forwarding rule", "port forwarding rules")
            case .metrics: ("a metrics monitor", "metrics monitors")
            }
        let verbs: (infinitive: String, progressive: String, past: String) =
            switch specification.action {
            case .list: ("list", "Listing", "Listed")
            case .get: ("read", "Reading", "Read")
            case .add: ("add", "Adding", "Added")
            case .edit: ("edit", "Editing", "Edited")
            case .delete: ("delete", "Deleting", "Deleted")
            case .generate: ("generate", "Generating", "Generated")
            case .start: ("start", "Starting", "Started")
            case .stop: ("stop", "Stopping", "Stopped")
            case .refresh: ("refresh", "Refreshing", "Refreshed")
            }
        let activity = specification.action == .list ? nouns.plural : nouns.single
        let states: [(AgentToolCard.State, String)] = [
            (.proposed, "Preparing to \(verbs.infinitive)"),
            (.reviewing, "Preparing to \(verbs.infinitive)"),
            (.waitingForApproval, "Waiting to \(verbs.infinitive)"),
            (.waitingForUser, "Waiting to \(verbs.infinitive)"),
            (.running, verbs.progressive),
            (.completed, verbs.past),
            (.denied, "Did not \(verbs.infinitive)"),
            (.failed, "Failed to \(verbs.infinitive)"),
            (.interrupted, "Interrupted while \(verbs.progressive.lowercased())"),
        ]
        for (state, prefix) in states {
            let card = try card(name, state: state)
            var single = "\(prefix) \(activity)"
            var batch = "\(prefix) \(nouns.plural) (2 times)"
            if state == .completed, specification.action == .start {
                single = "Start requested"
                batch = "Start requested (2 times)"
            }
            if state == .completed, specification.action == .refresh {
                single = "Refresh not requested"
                batch = "Refresh not requested (2 times)"
            }
            #expect(renderer.summary(for: card, locale: english) == single)
            #expect(renderer.batchSummary(for: [card], locale: english) == single)
            #expect(renderer.batchSummary(for: [card, card], locale: english) == batch)
        }
        let card = try card(name)
        let approval = renderer.approval(
            for: .init(invocation: card.invocation, descriptor: card.descriptor, userIntent: "Inspect"),
            locale: english)
        #expect(approval.title == "\(verbs.infinitive.capitalized) \(activity)")
    }

    @Test(arguments: [
        (TermindToolName.listHosts, "hosts"), (TermindToolName.listHostGroups, "host_groups"),
        (TermindToolName.listIdentities, "identities"), (TermindToolName.listKeys, "keys"),
        (TermindToolName.listSnippets, "snippets"), (TermindToolName.listSnippetPackages, "snippet_packages"),
        (TermindToolName.listPortForwardings, "port_forwardings"), (TermindToolName.listMetrics, "metrics"),
    ])
    func listCountsDescribeResultsWithoutChangingTheOperation(_ name: String, _ key: String) throws {
        for count in 0...2 {
            let values = (0..<count).map { index in
                AgentJSONValue.object([
                    "name": .string("ProdSSH \(index)"), "title": .string("ProdSSH \(index)"),
                    "display_name": .string("ProdSSH \(index)"),
                ])
            }
            let card = try card(name, result: [key: .array(values)])
            let content = try #require(ResourceToolCardPresentation.content(for: card, locale: english))
            #expect(content.title == "\(count) \(count == 1 ? "resource" : "resources")")
            #expect(content.rows.count == count)
            #expect(!renderer.summary(for: card, locale: english).contains("\(count)"))
            if let first = content.rows.first { #expect(first.title == "ProdSSH 0") }
            if count == 0 {
                #expect(AgentToolDetailPreview(content.detail).fullText.contains("No resources found"))
            }
        }
    }

    @Test func snippetExecutionKeepsAuthenticationConnectionAndTargetPresentation() throws {
        let states: [(AgentToolCard.State, String?, String)] = [
            (.proposed, nil, "Preparing to run a snippet on ProdSSH"),
            (.reviewing, nil, "Preparing to run a snippet on ProdSSH"),
            (.waitingForApproval, nil, "Waiting to run a snippet on ProdSSH"),
            (.waitingForUser, nil, "Waiting to authenticate with ProdSSH"),
            (.running, nil, "Connecting to ProdSSH"),
            (.running, "command", "Running a snippet on ProdSSH"),
            (.completed, nil, "Ran a snippet on ProdSSH"),
            (.denied, nil, "Did not run a snippet on ProdSSH"),
            (.failed, nil, "Failed to run a snippet on ProdSSH"),
            (.interrupted, nil, "Stopped waiting for a snippet on ProdSSH"),
        ]
        for (state, phase, expected) in states {
            var card = try card(TermindToolName.runSnippet, state: state)
            card.result?.metadata["presentation_phase"] = phase.map(AgentJSONValue.string)
            #expect(renderer.summary(for: card, hostName: "ProdSSH", locale: english) == expected)
        }
        let card = try card(TermindToolName.runSnippet)
        let approval = renderer.approval(
            for: .init(invocation: card.invocation, descriptor: card.descriptor, userIntent: "Run"),
            hostName: "ProdSSH", locale: english)
        #expect(approval.title == "Run a snippet on ProdSSH")
        #expect(renderer.batchSummary(for: [card], locale: english) == "Ran a snippet")
        #expect(renderer.batchSummary(for: [card, card], locale: english) == "Ran snippets (2 times)")
    }

    @Test func metricSamplesAndMonitorConfigurationHaveDifferentNames() throws {
        let card = try card(TermindToolName.getMetrics)
        #expect(renderer.summary(for: card, hostName: "ProdSSH", locale: english) == "Read host metrics on ProdSSH")
        #expect(renderer.batchSummary(for: [card, card], locale: english) == "Read host metrics (2 times)")
        let monitor = try self.card(TermindToolName.addMetrics)
        #expect(renderer.summary(for: monitor, locale: english) == "Added a metrics monitor")
    }

    @Test func requestBatchesNeverClaimThatStartingOrRefreshingFinished() throws {
        let requested = try card(TermindToolName.refreshMetrics, result: ["refresh_requested": .bool(true)])
        let skipped = try card(TermindToolName.refreshMetrics, result: ["refresh_requested": .bool(false)])
        #expect(renderer.summary(for: requested, locale: english) == "Refresh requested")
        #expect(renderer.batchSummary(for: [requested], locale: english) == "Refresh requested")
        #expect(
            renderer.batchSummary(for: [requested, skipped, requested], locale: english)
                == "Refresh requested (2 times), refresh not requested")
        var failed = requested
        failed.state = .failed
        failed.result?.isError = true
        #expect(
            renderer.batchSummary(for: [requested, failed], locale: english)
                == "Refresh requested, failed to refresh a metrics monitor")
        let first = try card(TermindToolName.startMetrics)
        let second = try card(TermindToolName.startPortForwarding)
        #expect(
            renderer.batchSummary(for: [first, first, second], locale: english)
                == "Start requested (2 times), start requested")
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr"])
    func countsUseLocalePluralRules(_ language: String) {
        let locale = Locale(identifier: language)
        for count in 0...2 {
            let expected: String =
                switch language {
                case "en": "\(count) \(count == 1 ? "target" : "targets")"
                case "de": "\(count) \(count == 1 ? "Ziel" : "Ziele")"
                case "fr": "\(count) \(count < 2 ? "cible" : "cibles")"
                case "ja": "\(count)個の対象"
                case "ko": "대상 \(count)개"
                case "zh-Hans": "\(count)目标"
                default: "\(count)目標"
                }
            #expect(AppLocalization.resolve(AppStrings.ResourceCards.targetCount(count), locale: locale) == expected)
            if language == "en" {
                for (copy, unit) in [
                    (AppStrings.ResourceCards.resourceCount(count), "resource"),
                    (AppStrings.ResourceCards.lineCount(count), "line"),
                    (AppStrings.ResourceCards.deviceCount(count), "device"),
                ] {
                    #expect(AppLocalization.resolve(copy, locale: locale) == "\(count) \(unit)\(count == 1 ? "" : "s")")
                }
                #expect(
                    AppLocalization.resolve(
                        AppStrings.ResourceTools.repeated("Listed snippets", count: count), locale: locale)
                        == "Listed snippets (\(count) \(count == 1 ? "time" : "times"))")
            }
        }
    }

    @Test(arguments: [
        ("en", "Added an identity", "Public key"),
        ("zh-Hans", "已添加身份", "公钥"),
        ("zh-Hant", "已新增身分", "公開金鑰"),
        ("ja", "認証情報の追加が完了しました", "公開鍵"),
        ("ko", "인증 프로필 추가 완료", "공개 키"),
        ("de", "Abgeschlossen: eine Identität hinzufügen", "Öffentlicher Schlüssel"),
        ("fr", "Terminé\u{00A0}: ajouter une identité", "Clé publique"),
    ])
    func localizedToolCopyKeepsUserContentIntact(_ language: String, _ summary: String, _ label: String) throws {
        let locale = Locale(identifier: language)
        #expect(renderer.summary(for: try card(TermindToolName.addIdentity), locale: locale) == summary)
        let publicKey = "ssh-ed25519 AAAATestCaseSensitive"
        let card = try card(
            TermindToolName.getKey,
            result: [
                "label": .string("Deploy SSH KEY"), "public_key": .string(publicKey),
                "storage": .string("secureEnclave"), "availability": .string("not_configured"),
            ])
        let content = try #require(ResourceToolCardPresentation.content(for: card, locale: locale))
        #expect(content.title == "Deploy SSH KEY")
        #expect(content.blocks.first?.title == label)
        #expect(content.blocks.first?.text == publicKey)
        if language == "en" {
            #expect(content.fields.contains { $0.value == "Secure Enclave" })
            #expect(content.fields.contains { $0.value == "Not configured" })
            #expect(AppLocalization.resolve(AppStrings.Assistant.allowOnce, locale: locale) == "Allow Once")
            #expect(
                AppLocalization.resolve(AppStrings.Assistant.suggestedCommand, locale: locale) == "Suggested Command")
            #expect(AppLocalization.resolve(AppStrings.Navigation.snippets, locale: locale) == "Snippets")
        }
    }

    @Test func historicalCardsGetNewCopyWithoutChangingMCPNamesOrCommandArguments() throws {
        let original = try card(TermindToolName.getSnippet, result: ["title": .string("DeploySSH")])
        var replay = original
        replay.descriptor = try JSONDecoder().decode(
            AgentToolDescriptor.self, from: JSONEncoder().encode(original.descriptor))
        replay.result = try JSONDecoder().decode(
            AgentToolResult?.self, from: JSONEncoder().encode(original.result))
        #expect(renderer.summary(for: replay, locale: english) == "Read a snippet")
        for name in [TermindToolName.listSnippets, TermindToolName.runSnippet] {
            var remote = try card(name)
            remote.descriptor.target = .mcp
            remote.descriptor.presentation?.activity = .label("Vendor.Snippets")
            remote.descriptor.presentation?.actionKind = .call
            remote.descriptor.presentation?.phaseKinds = [:]
            #expect(renderer.summary(for: remote, locale: english) == "Called Vendor.Snippets")
            #expect(
                renderer.batchSummary(for: [remote, remote], locale: english) == "Called Vendor.Snippets (2 times)")
        }
        let command = "cat /Var/SSH/Deploy.sh"
        let commandCard = try card(TermindToolName.sshExecRun, arguments: ["command": .string(command)])
        #expect(renderer.summary(for: commandCard, hostName: "ProdSSH", locale: english) == "Ran \(command) on ProdSSH")
        let fileCard = try card("sftp_read", arguments: ["path": .string("/Var/SSH/Deploy.sh")])
        #expect(renderer.summary(for: fileCard, locale: english) == "Read /Var/SSH/Deploy.sh")
    }

    private func card(
        _ name: String, state: AgentToolCard.State = .completed,
        arguments: [String: AgentJSONValue] = [:], result: [String: AgentJSONValue] = [:]
    ) throws -> AgentToolCard {
        let descriptor = try #require(descriptors[name])
        return .init(
            invocation: .init(runID: UUID(), call: .init(id: "call", name: name, arguments: .object(arguments))),
            descriptor: descriptor, state: state,
            result: .init(callID: "call", content: AgentJSONValue.object(result).encodedString))
    }
}

private final class EmptyMetricsPreferences: MetricsConfigurationStoring {
    func load() throws -> [MetricsSelection] { [] }
    func save(_ selections: [MetricsSelection]) throws {}
}

@MainActor
private final class UnusedForwardingRuntime: AgentForwardingControlling {
    func start(_ id: UUID) { Issue.record("Presentation tests must not start forwarding") }
    func stop(_ id: UUID) { Issue.record("Presentation tests must not stop forwarding") }
    func managementStatus(_ id: UUID) -> AgentForwardingStatus { .init(state: "stopped") }
}
