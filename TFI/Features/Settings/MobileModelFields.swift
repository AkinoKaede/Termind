import AgentKit
import SwiftUI

struct MobileModelFields: View {
    @Binding var model: AIModel
    let provider: ModelProvider

    var body: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $model.displayName).multilineTextAlignment(.trailing)
            }
            Picker("Type", selection: $model.kind) {
                ForEach(AIModel.Kind.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Show in Assistant", isOn: $model.isShownInAssistant)
        } header: {
            Text("Basics")
        } footer: {
            if model.origin == .manual { Text("Added Manually") }
        }

        Section("Input") {
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

        Section("Abilities") {
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

        Section("Limits") {
            LabeledContent("Context Window") {
                TextField("Context Window", value: $model.contextLength, format: .number)
                    .multilineTextAlignment(.trailing).keyboardType(.numberPad)
            }
            LabeledContent("Max Output") {
                TextField("Max Output", value: $model.maxOutputTokens, format: .number)
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
        Section("Reasoning Effort") {
            if model.reasoningProfile == nil {
                Text("Automatic from model catalog").font(.caption)
                Button("Customize", systemImage: "slider.horizontal.3") {
                    model.reasoningProfile = ModelCapabilityResolver.customProfile(from: automatic)
                }
                ForEach(automatic.supported) { effort in
                    LabeledContent(
                        effort.displayName,
                        value: automatic.wireValue(for: effort) ?? String(localized: "Provider default"))
                }
            } else {
                Text("Custom mapping").font(.caption)
                Button("Reset to Automatic", systemImage: "arrow.counterclockwise") { model.reasoningProfile = nil }
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
                        let count = model.reasoningProfile?.levels.values.filter(\.isSupported).count ?? 0
                        guard enabled || count > 1 else { return }
                        update(effort) { $0.isSupported = enabled }
                    }
                )
            )
            .toggleStyle(MobileCheckboxToggleStyle())
            .frame(width: 120, alignment: .leading)

            TextField(
                "Provider default",
                text: Binding(
                    get: { model.reasoningProfile?.mapping(for: effort).wireValue ?? "" },
                    set: { value in
                        update(effort) {
                            $0.wireValue =
                                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                        }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(!mapping.isSupported)
            .opacity(mapping.isSupported ? 1 : 0.55)
            .accessibilityLabel(Text("\(effort.displayName) provider value"))
        }
    }

    private func update(_ effort: ReasoningEffort, change: (inout ReasoningLevelMapping) -> Void) {
        var profile = model.reasoningProfile ?? ReasoningProfile()
        var mapping = profile.mapping(for: effort)
        change(&mapping)
        profile.levels[effort] = mapping
        model.reasoningProfile = profile
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
