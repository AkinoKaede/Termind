// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Trailing controls inside an answer field. Both recording actions stay on
/// the right; neither the draft nor a waveform takes their place.
public struct UserInputSpeechControls: View {
    private let isActive: Bool
    private let isRecording: Bool
    private let canStart: Bool
    private let start: () -> Void
    private let cancel: () -> Void
    private let stop: () -> Void

    public init(
        isActive: Bool, isRecording: Bool, canStart: Bool,
        start: @escaping () -> Void, cancel: @escaping () -> Void, stop: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.isRecording = isRecording
        self.canStart = canStart
        self.start = start
        self.cancel = cancel
        self.stop = stop
    }

    private var controlSize: CGFloat {
        #if os(iOS)
            44
        #else
            32
        #endif
    }

    public var body: some View {
        HStack(spacing: 2) {
            if isActive {
                control(AppStrings.Assistant.cancelTranscription, symbol: "xmark", action: cancel)
                    .accessibilityIdentifier("UserInputSpeech.Cancel")
                if isRecording {
                    control(AppStrings.Assistant.stopRecording, symbol: "stop.fill", action: stop)
                        .accessibilityIdentifier("UserInputSpeech.Stop")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: controlSize, height: controlSize)
                        .accessibilityLabel(Text(AppStrings.Assistant.transcribing))
                }
            } else {
                Button(action: start) {
                    Image(systemName: "mic")
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .accessibilityLabel(Text(AppStrings.Assistant.transcribe))
                .help(Text(AppStrings.Assistant.transcribeWithAppleSpeech))
                .accessibilityIdentifier("UserInputSpeech.Start")
            }
        }
        .fixedSize()
    }

    private func control(_ title: LocalizedStringResource, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            #if os(iOS)
                Image(systemName: symbol)
                    .font(.title3.weight(.medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: controlSize, height: controlSize)
                    .contentShape(.rect)
            #else
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.55), in: .circle)
                    .frame(width: controlSize, height: controlSize)
                    .contentShape(.rect)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }
}
