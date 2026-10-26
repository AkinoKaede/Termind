// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation

struct TerminalInputAreaView: View {
    @Bindable var model: TerminalInputAreaModel
    let availableHeight: Double
    let isActive: Bool
    let transcription: SpeechTranscriptionCoordinator
    let ai: AIConfigurationModel
    let configureModels: () -> Void
    let focusPane: () -> Void
    let send: () -> Void
    let generate: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.inputSendShortcut) private var sendShortcut = InputSendShortcut.returnKey
    @State private var dragStartHeight: Double?
    @State private var hasMarkedText = false
    @State private var editorID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            VStack(spacing: Metrics.Space.xs) {
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = model.error ?? (model.mode == .commandGenerator ? ai.storageError : nil) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Group {
                    if model.isTranscribing {
                        transcriptionControls
                    } else {
                        controls
                    }
                }
                .frame(height: 32)
                .animation(Motion.panel(reduceMotion: reduceMotion), value: model.isTranscribing)
            }
            .padding(Metrics.Space.s)
        }
        .background(TermindColor.windowSurface)
        .onDisappear {
            model.setEditorFocused(false, editorID: editorID)
            model.cancelTranscription()
        }
        .onChange(of: isActive) { _, active in
            if !active { model.cancelTranscription() }
        }
        .onChange(of: generatorModel) { _, _ in model.cancelGeneration() }
        .alert(
            model.transcriptionError?.title ?? String(localized: AppStrings.Assistant.transcriptionFailed),
            isPresented: Binding(
                get: { model.transcriptionError != nil },
                set: { if !$0 { model.dismissTranscriptionError() } })
        ) {
            if model.transcriptionError?.offersSystemSettings == true {
                Button(AppStrings.Assistant.openSystemSettings.swiftUIKey) {
                    let anchor =
                        model.transcriptionError?.code == .speechPermissionDenied
                        ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) {}
        } message: {
            Text(model.transcriptionError?.message ?? "")
        }
    }

    private var generatorModel: AIModelRef? {
        ai.resolve(.commandGenerator).map { .init(modelProviderID: $0.provider.id, modelID: $0.model.id) }
    }

    private var editor: some View {
        TerminalInputEditor(
            text: $model.draft,
            hasMarkedText: $hasMarkedText,
            isActive: isActive,
            focusRequest: model.focusRequest,
            accessibilityLabel: AppLocalization.resolve(AppStrings.TerminalInput.title, locale: locale),
            sendShortcut: sendShortcut,
            focusChanged: { focused in
                model.setEditorFocused(focused, editorID: editorID)
                if focused { focusPane() }
            },
            submit: submit,
            generate: {
                guard canSend else { return }
                generate()
            }
        )
        .overlay(alignment: .topLeading) {
            if model.draft.isEmpty, !hasMarkedText {
                Text(
                    model.mode == .input
                        ? AppStrings.TerminalInput.inputPrompt : AppStrings.TerminalInput.generationPrompt
                )
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, 5)
                .padding(.top, 4)
                .allowsHitTesting(false)
            }
        }
    }

    private var canSend: Bool {
        isActive && model.hasContent && !model.isGenerating && !model.isTranscribing && !hasMarkedText
    }

    private var canSubmit: Bool {
        canSend || (isActive && isRecording && !hasMarkedText)
    }

    private func submit() {
        guard canSubmit else { return }
        focusPane()
        if isRecording {
            model.submitTranscription()
        } else {
            send()
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controls(compactModel: false, compactMode: false)
            controls(compactModel: true, compactMode: false)
            controls(compactModel: true, compactMode: true)
        }
        .animation(Motion.panel(reduceMotion: reduceMotion), value: model.isGenerating)
    }

    private func controls(compactModel: Bool, compactMode: Bool) -> some View {
        HStack(alignment: .center, spacing: compactMode ? 0 : Metrics.Space.s) {
            modePicker(compact: compactMode)
            Spacer(minLength: 0)
            if model.mode == .commandGenerator {
                TerminalInputModelMenu(
                    ai: ai, compact: compactModel, selectionChanged: model.cancelGeneration, configure: configureModels)
            }
            trailingControls
        }
        .frame(height: 32)
    }

    private var isRecording: Bool {
        transcription.isOwned(by: model.transcriptionOwnerID) && transcription.phase == .recording
    }

    private var trailingControls: some View {
        HStack(alignment: .center, spacing: Metrics.Space.xs) {
            if model.isTranscribing {
                if isRecording {
                    speechControl(
                        title: AppStrings.Assistant.stopRecording, symbol: "stop.fill", action: model.stopTranscription
                    )
                    .accessibilityIdentifier("terminal-input.speech-stop")
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 26, height: 26)
                        .background(.quaternary.opacity(0.55), in: .circle)
                        .frame(width: 32, height: 32)
                        .accessibilityLabel(Text(AppStrings.Assistant.transcribing))
                }
            } else if model.isGenerating {
                ProgressView().controlSize(.small)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(Text(AppStrings.Workspace.generatingCommand))
            } else {
                Button {
                    focusPane()
                    model.startTranscription(using: transcription, submit: send)
                } label: {
                    Image(systemName: "mic")
                        .frame(width: 32, height: 32)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .termindInputAwareFocusEffect()
                .foregroundStyle(.secondary)
                .disabled(!isActive || !transcription.canStart(for: model.transcriptionOwnerID))
                .help(Text(AppStrings.Assistant.transcribeWithAppleSpeech))
                .accessibilityLabel(Text(AppStrings.Assistant.transcribe))
                .accessibilityIdentifier("terminal-input.speech-start")
            }
            if model.isGenerating {
                Button {
                    model.cancelGeneration()
                    model.requestEditorFocus()
                } label: {
                    Label(AppStrings.Common.stop.swiftUIKey, systemImage: "stop.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .termindInputAwareFocusEffect()
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
                .help(Text(AppStrings.Common.stop))
            } else {
                submitButton
            }
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            Image(systemName: model.mode == .input ? "arrow.up" : "square.and.pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TermindColor.windowSurface)
                .frame(width: 26, height: 26)
                .background(Color.primary, in: .circle)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .termindInputAwareFocusEffect()
        .contentShape(.circle)
        .help(
            Text(
                model.mode == .input
                    ? (sendShortcut == .returnKey
                        ? AppStrings.Assistant.sendWithReturn : AppStrings.Assistant.sendLabel)
                    : AppStrings.Workspace.generateCommand)
        )
        .accessibilityLabel(
            Text(
                model.mode == .input
                    ? AppStrings.Assistant.send : AppStrings.Workspace.generateCommand)
        )
        .disabled(!canSubmit)
        .accessibilityIdentifier("terminal-input.submit")
    }

    private func modePicker(compact: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(TerminalInputMode.allCases, id: \.self) { mode in
                Button {
                    model.mode = mode
                    model.requestEditorFocus()
                } label: {
                    HStack(spacing: Metrics.Space.xs) {
                        Image(systemName: mode == .input ? "text.cursor" : "sparkles")
                            .frame(width: 13)
                        if !compact { Text(mode.title).lineLimit(1) }
                    }
                    .font(.caption2)
                    .padding(.horizontal, compact ? 0 : Metrics.Space.s)
                    .frame(width: compact ? 24 : nil, height: 24)
                    .background {
                        if model.mode == mode {
                            Capsule()
                                .fill(TermindColor.windowSurface)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .termindInputAwareFocusEffect()
                .foregroundStyle(model.mode == mode ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .help(Text(mode.title))
                .accessibilityLabel(Text(mode.title))
                .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                .accessibilityIdentifier("terminal-input.mode.\(mode.rawValue)")
            }
        }
        .padding(Metrics.Space.xxs)
        .background(.quaternary.opacity(0.55), in: .capsule)
        .overlay { Capsule().stroke(.separator, lineWidth: 0.5).allowsHitTesting(false) }
        .fixedSize()
        .frame(height: 32, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.TerminalInput.mode))
    }

    private var transcriptionControls: some View {
        HStack(alignment: .center, spacing: Metrics.Space.s) {
            speechControl(title: AppStrings.Assistant.cancelTranscription, symbol: "xmark") {
                model.cancelTranscription()
                model.requestEditorFocus()
            }
            .accessibilityIdentifier("terminal-input.speech-cancel")
            if isRecording {
                SpeechWaveformView(samples: transcription.levelSamples, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(AppStrings.Assistant.recording))
            } else {
                Text(AppStrings.Assistant.transcribing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            trailingControls
        }
        .frame(height: 32)
    }

    private func speechControl(
        title: LocalizedStringResource, symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.quaternary.opacity(0.55), in: .circle)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .termindInputAwareFocusEffect()
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: Metrics.Split.dividerThickness)
            .overlay {
                Color.clear
                    .frame(height: Metrics.Split.dividerHitLength)
                    .contentShape(.rect)
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartHeight == nil {
                                    dragStartHeight = TerminalInputAreaModel.height(
                                        model.preferredHeight, available: availableHeight)
                                }
                                model.resize(
                                    to: (dragStartHeight ?? model.preferredHeight) - value.translation.height,
                                    available: availableHeight)
                            }
                            .onEnded { _ in dragStartHeight = nil }
                    )
            }
            .accessibilityLabel(Text(AppStrings.TerminalInput.resize))
            .accessibilityAdjustableAction { direction in
                let height = TerminalInputAreaModel.height(model.preferredHeight, available: availableHeight)
                switch direction {
                case .increment: model.resize(to: height + 16, available: availableHeight)
                case .decrement: model.resize(to: height - 16, available: availableHeight)
                @unknown default: break
                }
            }
    }
}
