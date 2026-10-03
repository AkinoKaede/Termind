import SwiftUI
import TermindApplication
import TermindDomain

public struct TailscaleLoginFields: View {
    @Bindable var editor: TailscaleGroupEditor
    let requireAccess: () -> Bool
    @State private var authKey = ""
    @State private var usesKey = false
    @State private var openedLoginURL: URL?
    @Environment(\.openURL) private var openURL

    public init(editor: TailscaleGroupEditor, requireAccess: @escaping () -> Bool) {
        self.editor = editor
        self.requireAccess = requireAccess
    }

    public var body: some View {
        Group {
            TextField(
                AppStrings.Vault.hostname.swiftUIKey, text: $editor.hostname,
                prompt: Text(verbatim: editor.model.defaultHostname)
            ).disabled(editor.isLoggingIn)
            TextField(
                AppStrings.Tailscale.controlURL.swiftUIKey, text: $editor.controlURL,
                prompt: Text(verbatim: TailscaleNetwork.defaultControlURL)
            ).disabled(editor.isLoggingIn)
            Picker(AppStrings.Vault.authentication.swiftUIKey, selection: $usesKey) {
                Text(AppStrings.Tailscale.interactive).tag(false)
                Text(AppStrings.Tailscale.authKey).tag(true)
            }.disabled(editor.isLoggingIn)
            if usesKey {
                SecureField(AppStrings.Tailscale.authKey.swiftUIKey, text: $authKey).disabled(editor.isLoggingIn)
            }
            HStack(spacing: 8) {
                if let url = editor.loginURL, validLoginURL(url) {
                    Button(AppStrings.Tailscale.openLogin.swiftUIKey) { openURL(url) }
                } else {
                    Button(AppStrings.Tailscale.login.swiftUIKey) {
                        guard requireAccess() else { return }
                        openedLoginURL = nil
                        editor.login(authKey: usesKey ? authKey : nil)
                        authKey = ""
                    }.disabled(editor.isLoggingIn || (usesKey && authKey.isEmpty))
                }
                if editor.isLoggingIn { ProgressView().controlSize(.small) }
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
}
