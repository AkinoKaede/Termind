import SwiftUI
import TermindApplication

/// Explicit flexible sizing keeps the native editor stable when it takes focus.
struct TailscaleHostnameField: View {
    @Bindable var editor: TailscaleGroupEditor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(AppStrings.Vault.hostname)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            TextField(
                AppStrings.Vault.hostname.swiftUIKey, text: $editor.hostname,
                prompt: Text(verbatim: editor.model.defaultHostname), axis: .horizontal
            )
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .tailscaleIdentifierInput()
            .frame(minWidth: 80, maxWidth: .infinity)
            .accessibilityIdentifier("tailscale.hostname")
        }
    }
}
