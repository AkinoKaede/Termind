// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

/// The same endpoint derivation is presented in desktop pages and mobile drafts.
public struct ModelProviderConnectionFields: View {
    @Binding private var isEnabled: Bool
    @Binding private var name: String
    @Binding private var endpoint: ProviderEndpoint
    private let showsEndpoint: Bool

    public init(
        name: Binding<String>, endpoint: Binding<ProviderEndpoint>, isEnabled: Binding<Bool>,
        showsEndpoint: Bool = true
    ) {
        _isEnabled = isEnabled
        _name = name
        _endpoint = endpoint
        self.showsEndpoint = showsEndpoint
    }

    private var preview: ProviderEndpoint { endpoint.withDefaultURL }

    public var body: some View {
        Section {
            LabeledContent(AppStrings.Common.name.swiftUIKey) {
                TextField(
                    AppStrings.Common.name.swiftUIKey, text: $name.singleLineText,
                    prompt: Text(verbatim: endpoint.apiType.defaultProviderName),
                    axis: .horizontal
                )
                .singleLinePaste().lineLimit(1).labelsHidden().multilineTextAlignment(.trailing)
            }
            Toggle(AppStrings.Common.enabled.swiftUIKey, isOn: $isEnabled)
            Picker("API Type", selection: $endpoint.apiType) {
                ForEach(ModelAPIType.allCases) { Text($0.displayName).tag($0) }
            }
        }
        if showsEndpoint {
            Section("Endpoint") {
                LabeledContent(AppStrings.Settings.url.swiftUIKey) {
                    TextField(
                        AppStrings.Settings.url.swiftUIKey, text: $endpoint.url.singleLineText,
                        prompt: Text(verbatim: endpoint.apiType.defaultURL),
                        axis: .horizontal
                    ).singleLinePaste().lineLimit(1)
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                if !ModelProviderForm.isValidURL(preview.requestURL) {
                    Text(AppStrings.Settings.enterAValidProviderUrlOrAVertexProjectAndLocation)
                        .font(.caption).foregroundStyle(.red)
                }
                if preview.isConfigured {
                    LabeledContent("Full URL") {
                        Text(preview.requestURL).font(.caption.monospaced()).textSelection(.enabled)
                            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Requests use the \(preview.format.displayName) format.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
