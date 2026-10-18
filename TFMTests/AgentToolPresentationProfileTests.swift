import AgentKit
import Foundation
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@Suite
struct AgentToolPresentationProfileTests {
    private let english = Locale(identifier: "en")

    @Test
    func injectedProfileControlsPhasesPendingDetailsApprovalAndTruncation() throws {
        var profile = AgentToolPresentationProfile()
        profile.phaseSummary = { phase, activity, target, _ in
            phase.rawValue == "uploading" ? "Uploading \(activity) to \(target ?? "destination")" : nil
        }
        profile.detail = { card, _, _ in
            card.result == nil ? .content(.init(items: [.message("Pending upload", .secondary)])) : .hidden
        }
        profile.requiresArgumentProjection = true
        profile.hidesTruncationNotice = true
        let configured = profile
        let renderer = AgentToolPresentation(profile: { _ in configured })
        var card = card(name: "unrelated_name", target: .local)
        card.descriptor.presentation = .init(
            symbol: "arrow.up", activity: .label("artifacts"), presenterID: "example.upload",
            actionKind: .push, phaseKinds: ["running": .init("uploading")])
        card.state = .running
        #expect(renderer.summary(for: card, hostName: "server", locale: english) == "Uploading artifacts to server")
        #expect(renderer.detail(for: card)?.items == [.message("Pending upload", .secondary)])
        #expect(AgentToolPresentation().summary(for: card, locale: english) == "Pushing artifacts")
        #expect(AgentToolPresentation().detail(for: card) == nil)

        let request = AgentApprovalRequest(
            invocation: card.invocation, descriptor: card.descriptor, userIntent: "Upload")
        #expect(renderer.approval(for: request, locale: english).detail.items.isEmpty)
        #expect(!AgentToolPresentation().approval(for: request, locale: english).detail.items.isEmpty)

        card.result = .init(callID: "call", content: "private payload")
        card.result?.truncateMarker = "truncated"
        #expect(renderer.detail(for: card) == nil)
        #expect(renderer.truncationNotice(for: card) == nil)
        #expect(AgentToolPresentation().truncationNotice(for: card) == "truncated")
    }

    @Test
    func injectedVocabularyCountsUnknownActivitiesWithoutToolNameRules() {
        var vocabulary = AgentToolPresentationVocabulary()
        vocabulary.activity = { _, _ in "a widget" }
        vocabulary.countedActivity = { _, count, _ in "\(count) widgets" }
        let renderer = AgentToolPresentation(vocabulary: vocabulary)
        var card = card(name: "custom_tool", target: .local)
        card.descriptor.presentation = .init(
            symbol: "shippingbox", activity: .semanticLabel(.init("widget")), actionKind: .create)
        card.state = .completed
        #expect(renderer.summary(for: card, locale: english) == "Created a widget")
        #expect(renderer.batchSummary(for: [card, card], locale: english) == "Created 2 widgets")
        card.state = .failed
        #expect(renderer.batchSummary(for: [card, card], locale: english) == "Failed to create 2 widgets")
    }

    @Test
    func explicitMCPPresenterIsUsedButRemoteMetadataCannotSelectLocalCode() throws {
        var card = card(name: "ssh_exec_run", target: .mcp)
        card.descriptor.presentation = .init(
            symbol: "terminal", activity: .label("remote"), output: .json,
            presenterID: SSHExecRunTool.presenter.id)
        card.result = .init(callID: "call", content: "{\"value\":42}")
        #expect(TermindAgentTools.presenter(for: card.descriptor) == nil)
        let presenter = AgentToolDetailPresenter(
            id: "example.remote", layout: .init(singleLineHeader: true),
            present: { input in
                [
                    .field(
                        .init(label: "Projected", value: input.result.objectValue?["value"]?.encodedString ?? "missing")
                    )
                ]
            })
        let detail = try #require(TermindToolPresentationProfiles.renderer.detail(for: card, presenter: presenter))
        #expect(detail.items == [.field(.init(label: "Projected", value: "42"))])
        #expect(detail.layout.singleLineHeader)
        let fallback = try #require(TermindToolPresentationProfiles.renderer.detail(for: card))
        #expect(fallback.items != detail.items)
        #expect(AgentToolDetailPreview(fallback).fullText.contains("\"value\""))
    }

    @Test
    func registeredProfileFollowsItsIDNotTheToolName() {
        var card = card(name: "renamed_command", target: .host)
        card.descriptor.presentation = .init(
            symbol: "terminal", activity: .label("command"), presenterID: SSHExecRunTool.presenter.id,
            actionKind: .run, phaseKinds: ["running": .sshConnecting])
        card.state = .running
        #expect(TermindToolPresentationProfiles.renderer.summary(for: card, locale: english) == "Connecting")
        card.descriptor.presentation?.presenterID = "unknown.command"
        #expect(TermindToolPresentationProfiles.renderer.summary(for: card, locale: english) == "Running command")
        #expect(TermindToolPresentationProfiles.renderer.detail(for: card) == nil)
        card.descriptor.name = "ssh_exec_run"
        card.descriptor.presentation = nil
        #expect(TermindAgentTools.presenter(for: card.descriptor) == nil)
        #expect(TermindToolPresentationProfiles.renderer.summary(for: card, locale: english) == "Running ssh exec run")
        #expect(TermindToolPresentationProfiles.renderer.detail(for: card) == nil)
    }

    private func card(name: String, target: AgentToolDescriptor.Target) -> AgentToolCard {
        .init(
            invocation: .init(
                runID: UUID(), call: .init(id: "call", name: name, arguments: .object(["secret": .string("private")]))),
            descriptor: .init(
                name: name, summary: name, inputSchema: .object([:]), target: target, approvalPolicy: .ask))
    }
}
