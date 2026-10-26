// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation

struct TerminalInputModelMenu: View {
    let ai: AIConfigurationModel
    let compact: Bool
    let selectionChanged: () -> Void
    let configure: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Menu {
            Picker(
                AppStrings.Assistant.model.swiftUIKey,
                selection: Binding(
                    get: { ai.assignment(for: .commandGenerator) },
                    set: {
                        selectionChanged()
                        ai.assign($0, to: .commandGenerator)
                    })
            ) {
                Text(AIRole.commandGenerator.unsetLabel).tag(AIModelRef?.none)
                ForEach(ai.enabledModelProviders.filter { !$0.chatModels.isEmpty }) { provider in
                    Section(provider.name) {
                        ForEach(provider.chatModels) { model in
                            Text(model.label)
                                .tag(AIModelRef?.some(.init(modelProviderID: provider.id, modelID: model.id)))
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button(AppStrings.Assistant.configureModelProviders.swiftUIKey, systemImage: "slider.horizontal.3") {
                configure()
            }
        } label: {
            TerminalInputMenuLabel(
                title: ai.resolve(.commandGenerator)?.model.label
                    ?? AppLocalization.resolve(AppStrings.Assistant.model, locale: locale),
                symbol: WindowSidebarState.Mode.assistant.symbol,
                compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .termindInputAwareFocusEffect()
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(
            Text(
                AppStrings.Assistant.modelHelp(
                    modelName: ai.resolve(.commandGenerator)?.model.label,
                    providerName: ai.resolve(.commandGenerator)?.provider.name,
                    effortName: nil))
        )
        .accessibilityLabel(Text(AppStrings.Assistant.model))
        .accessibilityValue(ai.resolve(.commandGenerator)?.model.label ?? "")
    }
}

struct TerminalInputMenuLabel: View {
    let title: String
    let symbol: String
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                Image(systemName: symbol)
                    .frame(width: 24, height: 24)
                    .contentShape(.circle)
            } else {
                HStack(spacing: Metrics.Space.xs) {
                    Image(systemName: symbol)
                        .font(.caption2)
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
        }
        .font(.callout)
        .frame(height: 32, alignment: .center)
    }
}
