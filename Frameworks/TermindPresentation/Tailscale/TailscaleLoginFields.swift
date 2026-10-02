import SwiftUI
import TermindApplication
import TermindDomain

public struct TailscaleLoginFields: View {
    let model: TailscaleModel
    let name: String
    let parentID: UUID?
    let group: HostGroup?
    let completed: (UUID) -> Void
    @State private var hostname = ""
    @State private var controlURL = ""
    @State private var authKey = ""
    @State private var usesKey = false
    @State private var openedLoginURL: URL?
    @Environment(\.openURL) private var openURL

    public init(
        model: TailscaleModel, name: String, parentID: UUID?, group: HostGroup?,
        completed: @escaping (UUID) -> Void
    ) {
        self.model = model
        self.name = name
        self.parentID = parentID
        self.group = group
        self.completed = completed
        _hostname = State(initialValue: group.flatMap { model.savedHostname(groupID: $0.id) } ?? "")
        let savedControlURL = group?.tailscale?.network.controlURL ?? ""
        _controlURL = State(initialValue: savedControlURL == TailscaleNetwork.defaultControlURL ? "" : savedControlURL)
    }

    public var body: some View {
        Group {
            TextField(
                AppStrings.Vault.hostname.swiftUIKey, text: $hostname,
                prompt: Text(verbatim: model.defaultHostname)
            ).disabled(model.isLoggingIn)
            TextField(
                AppStrings.Tailscale.controlURL.swiftUIKey, text: $controlURL,
                prompt: Text(verbatim: TailscaleNetwork.defaultControlURL)
            )
            .disabled(group?.tailscale != nil || model.isLoggingIn)
            .onChange(of: model.loginCompletedGroupID) { _, id in if let id { completed(id) } }
            .onChange(of: model.loginURL) { _, url in
                guard let url, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                    openedLoginURL != url
                else { return }
                openedLoginURL = url
                openURL(url)
            }
            .onDisappear {
                model.cancelLogin()
                authKey = ""
            }
            Picker(AppStrings.Vault.authentication.swiftUIKey, selection: $usesKey) {
                Text(AppStrings.Tailscale.interactive).tag(false)
                Text(AppStrings.Tailscale.authKey).tag(true)
            }.disabled(model.isLoggingIn)
            if usesKey {
                SecureField(AppStrings.Tailscale.authKey.swiftUIKey, text: $authKey).disabled(model.isLoggingIn)
            }
            if model.isLoggingIn { ProgressView() }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if let url = model.loginURL, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil {
                Button(AppStrings.Tailscale.openLogin.swiftUIKey) { openURL(url) }
            } else {
                Button(AppStrings.Tailscale.login.swiftUIKey) {
                    openedLoginURL = nil
                    let enteredControlURL = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.beginLogin(
                        name: name, parentID: parentID,
                        controlURL: enteredControlURL.isEmpty ? TailscaleNetwork.defaultControlURL : enteredControlURL,
                        authKey: usesKey ? authKey : nil, groupID: group?.id, hostname: hostname)
                    authKey = ""
                }.disabled(model.isLoggingIn || name.isEmpty || (usesKey && authKey.isEmpty))
            }
        }
    }
}
