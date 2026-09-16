import SwiftUI
import TermindDomain

/// The same endpoint derivation is presented in desktop pages and mobile drafts.
public struct ModelProviderConnectionFields: View {
    @Binding private var isEnabled: Bool
    @Binding private var name: String
    @Binding private var endpoint: ProviderEndpoint

    public init(name: Binding<String>, endpoint: Binding<ProviderEndpoint>, isEnabled: Binding<Bool>) {
        _isEnabled = isEnabled
        _name = name
        _endpoint = endpoint
    }

    public var body: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $name.singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }
            Toggle("Enabled", isOn: $isEnabled)
            Picker("API Type", selection: $endpoint.apiType) {
                ForEach(ModelAPIType.allCases) { Text($0.displayName).tag($0) }
            }
        }
        Section("Endpoint") {
            LabeledContent("URL") {
                TextField("URL", text: $endpoint.url.singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            if endpoint.isConfigured {
                LabeledContent("Full URL") {
                    Text(endpoint.requestURL).font(.caption.monospaced()).textSelection(.enabled)
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                Text("Requests use the \(endpoint.format.displayName) format.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
