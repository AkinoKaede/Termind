// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import MarkdownView
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileAssistantPlanRow: View {
    let card: AgentPlanCard
    let presentation: AssistantTranscriptPresentationState
    let readOnly: Bool
    let isStreaming: Bool
    let implement: () -> Void
    let discard: () -> Void

    private var expanded: Bool { presentation.isExpanded(.plan(card.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                presentation.toggleDisclosure(.plan(card.id))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(tint)
                    Text(card.plan.title).font(.headline).lineLimit(expanded ? nil : 1)
                    Spacer(minLength: 0)
                    if card.outcome == .implemented {
                        Text(AppStrings.Assistant.implemented).font(.caption).foregroundStyle(.secondary)
                    } else if card.outcome == .discarded {
                        Text(AppStrings.Assistant.discarded).font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44).contentShape(.rect)
            }.buttonStyle(.plain)
            MobileAssistantMarkdown(text: card.plan.body)
                .frame(maxHeight: expanded ? nil : 112, alignment: .top).clipped()
                .contentShape(.rect)
                .onTapGesture { if !expanded { presentation.toggleDisclosure(.plan(card.id)) } }
            if card.outcome == .pending && !readOnly {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        discardButton
                        Spacer(minLength: 12)
                        planningHint.fixedSize(horizontal: true, vertical: false)
                        implementButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        planningHint.fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            discardButton
                            Spacer(minLength: 12)
                            implementButton
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(uiColor: .separator), lineWidth: 1) }
    }

    private var discardButton: some View {
        Button(AppStrings.Common.discard.swiftUIKey, role: .destructive, action: discard).frame(minHeight: 44)
    }

    private var implementButton: some View {
        Button(AppStrings.Assistant.implement.swiftUIKey, systemImage: "play", action: implement)
            .buttonStyle(.borderedProminent).disabled(isStreaming)
    }

    private var planningHint: some View {
        Text(AppStrings.Assistant.replyToKeepPlanning).font(.caption).foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch card.outcome {
        case .pending: "lightbulb.max"
        case .implemented: "checkmark.circle.fill"
        case .discarded: "xmark.circle"
        }
    }

    private var tint: Color {
        switch card.outcome {
        case .pending: .accentColor
        case .implemented: .green
        case .discarded: .secondary
        }
    }
}

struct MobileAssistantCommandRow: View {
    let command: SuggestedCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SuggestedCommandCodeBlock(command.command)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(command.risk.reasons, id: \.self) { reason in
                    Text(verbatim: "• \(reason)").font(.caption2).foregroundStyle(riskColor)
                }
                HStack {
                    Spacer()
                    Label(command.risk.risk.label, systemImage: command.risk.risk.symbol)
                        .font(.caption.weight(.medium)).foregroundStyle(riskColor)
                }
            }
            .padding(.top, 8).padding([.horizontal, .bottom], 12)
        }
        .background(Color(uiColor: MarkdownTheme().colors.codeBlockBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var riskColor: Color {
        switch command.risk.risk {
        case .safe: .green
        case .caution: .orange
        case .destructive: .red
        }
    }
}
