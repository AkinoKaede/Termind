// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileAssistantWorkRow: View {
    let group: AgentWorkGroup
    let presentation: AssistantTranscriptPresentationState
    let hostName: (UUID) -> String
    @Environment(\.locale) private var locale
    @Environment(\.mobileListRowIsDisplayed) private var displayed
    @Environment(\.mobileListSceneIsActive) private var sceneIsActive

    private var defaultExpanded: Bool {
        AgentWorkPresentation.isExpandedByDefault(for: group.run.state, appearsAfterAnswer: group.appearsAfterAnswer)
    }

    var body: some View {
        VStack(spacing: 12) {
            MobileAssistantDisclosure(
                expanded: presentation.isExpanded(.work(group.id), default: defaultExpanded),
                toggle: { presentation.toggleDisclosure(.work(group.id), default: defaultExpanded) }
            ) {
                if !group.run.state.isTerminal && displayed && sceneIsActive {
                    TimelineView(.periodic(from: .now, by: 1)) { context in workTitle(now: context.date) }
                } else {
                    workTitle(now: group.run.finishedAt ?? .now)
                }
            } content: {
                VStack(alignment: .leading, spacing: AssistantTranscriptStyle.blockSpacing) {
                    ForEach(group.items) { item in
                        switch item {
                        case .reasoning(let block):
                            MobileAssistantMarkdown(text: block.text, secondary: true)
                                .modifier(MobileAssistantScanning(active: group.activeReasoningBlockID == block.id))
                        case .message(let message):
                            if message.text.isEmpty && message.isStreaming {
                                MobileAssistantActivity(
                                    reconnectingTitle: group.retryProgress.map {
                                        AgentWorkPresentation.reconnectingTitle($0, locale: locale)
                                    }
                                )
                            } else if !message.text.isEmpty {
                                MobileAssistantMarkdown(text: message.text)
                            }
                        case .tool(let card):
                            MobileAssistantToolRow(card: card, presentation: presentation, hostName: hostName)
                        case .tools(let batch):
                            MobileAssistantToolBatchRow(batch: batch, presentation: presentation, hostName: hostName)
                        }
                    }
                }
            }
            Divider()
        }
    }

    private func workTitle(now: Date) -> some View {
        Text(
            group.retryProgress.map {
                AgentWorkPresentation.reconnectingTitle($0, locale: locale)
            }
                ?? AgentWorkPresentation.title(
                    for: group.run.state, from: group.run.startedAt,
                    to: group.run.finishedAt ?? now, locale: locale
                )
        )
        .font(.callout)
        .foregroundStyle(
            group.retryProgress == nil
                ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
        )
        .monospacedDigit()
    }
}

struct MobileAssistantToolRow: View {
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 16
    let card: AgentToolCard
    let presentation: AssistantTranscriptPresentationState
    let hostName: (UUID) -> String
    let defaultExpanded: Bool
    @Environment(\.locale) private var locale

    init(
        card: AgentToolCard,
        presentation: AssistantTranscriptPresentationState,
        hostName: @escaping (UUID) -> String,
        defaultExpanded: Bool = false
    ) {
        self.card = card
        self.presentation = presentation
        self.hostName = hostName
        self.defaultExpanded = defaultExpanded
    }

    var body: some View {
        let expanded = presentation.isExpanded(.tool(card.id), default: defaultExpanded)
        let presenter = MobileAppDependencies.toolPresenter(for: card.descriptor)
        MobileAssistantDisclosure(expanded: expanded, toggle: toggle) {
            HStack(spacing: 8) {
                Image(systemName: TermindToolPresentationProfiles.renderer.symbol(for: card))
                    .foregroundStyle(TermindToolPresentationProfiles.renderer.tint(for: card.state).color)
                    .font(.system(size: iconSize)).frame(width: iconSize)
                Text(
                    TermindToolPresentationProfiles.renderer.summary(
                        for: card, hostName: card.invocation.targetHostID.map(hostName), locale: locale
                    )
                )
                .foregroundStyle(card.state == .running ? Color.secondary : .primary)
                .lineLimit(presenter?.layout.singleLineHeader == true ? 1 : (expanded ? nil : 1))
                .modifier(MobileAssistantScanning(active: card.state == .running))
                if card.state == .reviewing {
                    Image(systemName: "checkmark.shield").foregroundStyle(.orange)
                        .accessibilityLabel(Text(AppStrings.Assistant.autoReviewingInProgress))
                }
            }
            .font(.callout).opacity(card.state == .interrupted ? 0.5 : 1)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let review = card.review {
                    Text(AppStrings.Assistant.automaticReview(risk: review.risk.displayName, reason: review.reason))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let content = ResourceToolCardPresentation.content(for: card, locale: locale) {
                    ResourceToolCardView(
                        content: content,
                        expanded: Binding(
                            get: { presentation.isExpanded(.toolDetail(card.id)) },
                            set: { value in
                                if value != presentation.isExpanded(.toolDetail(card.id)) {
                                    presentation.toggleDisclosure(.toolDetail(card.id))
                                }
                            }))
                } else if let detail = TermindToolPresentationProfiles.renderer.detail(
                    for: card, presenter: presenter, locale: locale
                ) {
                    AssistantCompactToolDetails(
                        detail: detail, isError: card.result?.isError == true,
                        expanded: Binding(
                            get: { presentation.isExpanded(.toolDetail(card.id)) },
                            set: { value in
                                if value != presentation.isExpanded(.toolDetail(card.id)) {
                                    presentation.toggleDisclosure(.toolDetail(card.id))
                                }
                            }
                        ),
                        truncateMarker: TermindToolPresentationProfiles.renderer.truncationNotice(for: card)
                    )
                }
            }
            .padding(.leading, iconSize + 8)
        }
    }
    private func toggle() { presentation.toggleDisclosure(.tool(card.id), default: defaultExpanded) }

}

private struct MobileAssistantToolBatchRow: View {
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 16
    let batch: AgentToolBatch
    let presentation: AssistantTranscriptPresentationState
    let hostName: (UUID) -> String
    @Environment(\.locale) private var locale
    @Environment(\.mobileListRowIsDisplayed) private var displayed
    @Environment(\.mobileListSceneIsActive) private var sceneIsActive
    @State private var deadline: Date?
    @State private var now = Date.now

    private var hasUnfinishedTools: Bool { batch.cards.contains { !$0.state.isTerminal } }
    private var reasoning: AgentToolReasoning? { hasUnfinishedTools ? batch.reasoning : nil }
    private var showsReasoning: Bool { reasoning != nil && deadline.map { $0 > now } == true }

    @ViewBuilder
    var body: some View {
        if batch.cards.count == 1, let card = batch.cards.first {
            MobileAssistantToolRow(
                card: card,
                presentation: presentation,
                hostName: hostName
            )
        } else {
            MobileAssistantDisclosure(
                expanded: presentation.isExpanded(.toolBatch(batch.id)),
                toggle: { presentation.toggleDisclosure(.toolBatch(batch.id)) }
            ) {
                HStack(spacing: 8) {
                    Image(systemName: TermindToolPresentationProfiles.renderer.batchSymbol(for: batch.cards))
                        .foregroundStyle(TermindToolPresentationProfiles.renderer.batchTint(for: batch.cards).color)
                        .font(.system(size: iconSize)).frame(width: iconSize)
                    Group {
                        if showsReasoning, let reasoning {
                            Text(TermindMarkdownParser.inlineTitle(reasoning.markdown))
                        } else {
                            Text(fallbackTitle)
                        }
                    }
                    .lineLimit(1).foregroundStyle(.secondary)
                    .modifier(MobileAssistantScanning(active: hasUnfinishedTools))
                }
                .font(.callout)
            } content: {
                VStack(alignment: .leading, spacing: AssistantTranscriptStyle.blockSpacing) {
                    ForEach(batch.cards) { card in
                        MobileAssistantToolRow(card: card, presentation: presentation, hostName: hostName)
                    }
                }
            }
            .task(id: TitleUpdate(revision: reasoning?.revision, displayed: displayed, sceneIsActive: sceneIsActive)) {
                guard displayed, sceneIsActive, let reasoning else { return }
                now = .now
                let expires = presentation.reasoningTitleDeadline(for: batch.id, revision: reasoning.revision)
                deadline = expires
                guard expires > now else { return }
                do {
                    try await Task.sleep(for: .seconds(expires.timeIntervalSinceNow))
                    now = .now
                } catch {}
            }
        }
    }

    private struct TitleUpdate: Equatable {
        var revision: String?
        var displayed: Bool
        var sceneIsActive: Bool
    }

    private var fallbackTitle: String {
        TermindToolPresentationProfiles.renderer.batchFallbackTitle(
            for: batch.cards, hostName: hostName, locale: locale)
    }
}
