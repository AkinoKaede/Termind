import AgentKit
import SwiftUI
import TermindDomain
import TermindPresentation

struct MobileModelFields: View {
    @Binding var model: AIModel
    let provider: ModelProvider

    var body: some View {
        Section {
            LabeledContent(AppStrings.Common.name.swiftUIKey) {
                TextField(
                    AppStrings.Common.name.swiftUIKey, text: $model.displayName.singleLineText,
                    prompt: Text(verbatim: model.id), axis: .horizontal
                ).singleLinePaste()
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
            Picker(AppStrings.Common.type.swiftUIKey, selection: $model.kind) {
                ForEach(AIModel.Kind.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle(AppStrings.Settings.showInAssistant.swiftUIKey, isOn: $model.isShownInAssistant)
        } header: {
            Text(AppStrings.Settings.basics)
        } footer: {
            if model.origin == .manual { Text(AppStrings.Settings.addedManually) }
        }

        Section(AppStrings.Settings.input.swiftUIKey) {
            ForEach(AIModel.Modality.allCases) { modality in
                Toggle(
                    modality.displayName,
                    isOn: Binding(
                        get: { model.input.contains(modality) },
                        set: { value in
                            if value {
                                model.input.insert(modality)
                            } else if modality != .text {
                                model.input.remove(modality)
                            }
                        })
                ).disabled(modality == .text)
            }
        }

        Section(AppStrings.Settings.abilities.swiftUIKey) {
            ForEach(AIModel.Ability.allCases) { ability in
                Toggle(
                    ability.displayName,
                    isOn: Binding(
                        get: { model.abilities.contains(ability) },
                        set: { value in
                            if value { model.abilities.insert(ability) } else { model.abilities.remove(ability) }
                        }))
            }
        }

        if model.abilities.contains(.reasoning) { reasoning }

        Section(AppStrings.Settings.limits.swiftUIKey) {
            LabeledContent(AppStrings.Settings.contextWindow.swiftUIKey) {
                TextField(AppStrings.Settings.contextWindow.swiftUIKey, value: $model.contextLength, format: .number)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing).keyboardType(.numberPad)
            }
            LabeledContent(AppStrings.Settings.maxOutput.swiftUIKey) {
                TextField(AppStrings.Settings.maxOutput.swiftUIKey, value: $model.maxOutputTokens, format: .number)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing).keyboardType(.numberPad)
            }
        }
    }

    private var automatic: ModelCapabilityResolver.ReasoningResolution {
        var value = model
        value.reasoningProfile = nil
        return ModelCapabilityResolver.reasoning(model: value, provider: provider)
    }

    private var reasoning: some View {
        Section(AppStrings.Settings.reasoningEffort.swiftUIKey) {
            if model.reasoningProfile == nil {
                Text(AppStrings.Settings.automaticFromModelCatalog).font(.caption)
                Button(AppStrings.Common.customize.swiftUIKey, systemImage: "slider.horizontal.3") {
                    model.reasoningProfile = ModelCapabilityResolver.customProfile(from: automatic)
                }
                ForEach(automatic.supported) { effort in
                    LabeledContent(
                        effort.displayName,
                        value: automatic.wireValue(for: effort)
                            ?? String(localized: AppStrings.Settings.providerDefault))
                }
            } else {
                Text(AppStrings.Settings.customMapping).font(.caption)
                Button(AppStrings.Settings.resetToAutomatic.swiftUIKey, systemImage: "arrow.counterclockwise") {
                    model.reasoningProfile = nil
                }
                ForEach(ReasoningEffort.allCases) { effort in
                    reasoningLevelRow(effort)
                }
            }
        }
    }

    private func reasoningLevelRow(_ effort: ReasoningEffort) -> some View {
        let mapping = model.reasoningProfile?.mapping(for: effort) ?? ReasoningLevelMapping(isSupported: false)

        return HStack(spacing: 12) {
            Toggle(
                effort.displayName,
                isOn: Binding(
                    get: { model.reasoningProfile?.mapping(for: effort).isSupported ?? false },
                    set: { enabled in
                        _ = model.setReasoningEffort(effort, isSupported: enabled)
                    }
                )
            )
            .toggleStyle(MobileCheckboxToggleStyle())
            .frame(width: 120, alignment: .leading)

            TextField(
                AppStrings.Settings.providerDefault.swiftUIKey,
                text: Binding(
                    get: { model.reasoningProfile?.mapping(for: effort).wireValue ?? "" },
                    set: { value in
                        model.setReasoningWireValue(
                            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value,
                            for: effort
                        )
                    }
                ).singleLineText, axis: .horizontal
            ).singleLinePaste().lineLimit(1)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!mapping.isSupported)
                .opacity(mapping.isSupported ? 1 : 0.55)
                .accessibilityLabel(Text(AppStrings.Settings.reasoningProviderValue(effort.displayName)))
        }
    }

}

private struct MobileCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                configuration.label
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(
                isOn: Binding(
                    get: { configuration.isOn },
                    set: { configuration.isOn = $0 }
                )
            ) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}
