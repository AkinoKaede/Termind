// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import UniformTypeIdentifiers

/// A prompt-local draft: multiline paste and file import never enter ordinary chat input.
public struct AgentSecretInput: View {
    @Binding private var text: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var multiline = false
    @State private var revealed = false
    @State private var importing = false
    @State private var importFailed = false
    @State private var active = false

    public init(text: Binding<String>) { _text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if multiline {
                HStack {
                    Text(
                        text.isEmpty ? AppStrings.ResourceTools.noSecretEntered : AppStrings.ResourceTools.secretEntered
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(
                        Text(revealed ? AppStrings.Settings.hideSecret : AppStrings.Settings.showSecret))
                }
                if revealed {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 180)
                        .autocorrectionDisabled()
                        .submitScope()
                }
            } else {
                RevealableSecretField(AppStrings.Keychain.secret, text: $text, appearance: .roundedBorder)
            }
            Toggle(AppStrings.ResourceTools.multilineInput.swiftUIKey, isOn: $multiline)
                .toggleStyle(.switch)
            HStack {
                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first,
                        let validated = try? AgentSecretFileInput.decode(Data(value.utf8))
                    else {
                        importFailed = true
                        return
                    }
                    text = validated
                    multiline = value.contains("\n") || value.contains("\r")
                    revealed = false
                    importFailed = false
                }
                Button(AppStrings.Keychain.chooseFile.swiftUIKey) { importing = true }
            }
            if importFailed {
                Text(AppStrings.ResourceTools.secretImportFailed).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard active else { return }
            do {
                text = try AgentSecretFileInput.read(result.get())
                multiline = true
                revealed = false
                importFailed = false
            } catch {
                importFailed = true
            }
        }
        .onChange(of: multiline) { _, _ in revealed = false }
        .onAppear { active = true }
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = false } }
        .onDisappear {
            active = false
            revealed = false
        }
    }
}
