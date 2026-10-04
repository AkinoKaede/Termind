import SwiftUI
import TermindApplication
import TermindDomain

public struct TailscaleLoginFields: View {
    @Bindable var editor: TailscaleGroupEditor
    let requireAccess: () -> Bool
    @State private var authKey = ""
    @State private var usesKey = false
    @State private var showsAdvanced: Bool
    @State private var openedLoginURL: URL?
    @Environment(\.openURL) private var openURL

    public init(editor: TailscaleGroupEditor, requireAccess: @escaping () -> Bool) {
        self.editor = editor
        self.requireAccess = requireAccess
        let controlURL = editor.controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        _showsAdvanced = State(initialValue: !controlURL.isEmpty && controlURL != TailscaleNetwork.defaultControlURL)
    }

    public var body: some View {
        Group {
            TailscaleHostnameField(editor: editor).disabled(editor.isLoggingIn)
            Picker(AppStrings.Vault.authentication.swiftUIKey, selection: $usesKey) {
                Text(AppStrings.Tailscale.interactive).tag(false)
                Text(AppStrings.Tailscale.authKey).tag(true)
            }.pickerStyle(.menu).disabled(editor.isLoggingIn)
            if usesKey {
                LabeledContent(AppStrings.Tailscale.authKey.swiftUIKey) {
                    SecureField(AppStrings.Tailscale.authKey.swiftUIKey, text: $authKey)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .tailscaleIdentifierInput()
                }.disabled(editor.isLoggingIn)
            }
            DisclosureGroup(AppStrings.Tailscale.advanced.swiftUIKey, isExpanded: $showsAdvanced) {
                LabeledContent(AppStrings.Tailscale.controlURL.swiftUIKey) {
                    TextField(
                        AppStrings.Tailscale.controlURL.swiftUIKey, text: $editor.controlURL,
                        prompt: Text(verbatim: TailscaleNetwork.defaultControlURL), axis: .horizontal
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .tailscaleIdentifierInput()
                    .accessibilityIdentifier("tailscale.controlURL")
                    #if os(iOS)
                        .keyboardType(.URL)
                    #endif
                }
            }.disabled(editor.isLoggingIn)
            Group {
                if let url = editor.loginURL, validLoginURL(url) {
                    Button {
                        openURL(url)
                    } label: {
                        actionLabel(AppStrings.Tailscale.openLogin, symbol: "arrow.up.right.square")
                    }
                } else {
                    Button {
                        guard requireAccess() else { return }
                        openedLoginURL = nil
                        editor.login(authKey: usesKey ? authKey : nil)
                        authKey = ""
                    } label: {
                        actionLabel(AppStrings.Tailscale.login, symbol: "rectangle.portrait.and.arrow.forward")
                    }
                    .disabled(editor.isLoggingIn || (usesKey && authKey.isEmpty))
                }
            }
            #if os(macOS)
                .buttonStyle(.plain)
            #endif
            if editor.isLoggingIn {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressView().controlSize(.small)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text(editor.loginURL == nil ? AppStrings.Tailscale.signingIn : AppStrings.Tailscale.waitingForLogin)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: editor.loginURL) { _, url in
            guard let url, validLoginURL(url), openedLoginURL != url else { return }
            openedLoginURL = url
            openURL(url)
        }
        .onDisappear { authKey = "" }
    }

    private func validLoginURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    @ViewBuilder private func actionLabel(_ title: LocalizedStringResource, symbol: String) -> some View {
        #if os(macOS)
            Label(title.swiftUIKey, systemImage: symbol)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        #else
            Text(title)
        #endif
    }
}
