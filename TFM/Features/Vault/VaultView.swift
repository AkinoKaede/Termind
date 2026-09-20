import SwiftUI

/// The first pinned destination's main content. Its navigator is mounted by the
/// window-level split view and remains alive while top-level destinations change.
struct VaultView: View {
    @Environment(WindowModel.self) private var window
    let pages: VaultPageStates

    init(pages: VaultPageStates = VaultPageStates()) {
        self.pages = pages
    }

    var body: some View {
        destination
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var destination: some View {
        switch window.vaultDestination {
        case .welcome: WelcomeView()
        case .hosts: HostsPageView(state: pages.hosts)
        case .keychain: KeychainPageView(state: pages.keychain)
        case .portForwarding: PortForwardingPageView(state: pages.portForwarding)
        case .snippets: SnippetsPageView(state: pages.snippets)
        case .knownHosts: KnownHostsPageView(state: pages.knownHosts)
        }
    }
}

struct VaultWorkDetailView: View {
    let route: VaultWorkRoute

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @ViewBuilder
    var body: some View {
        switch route {
        case .hostEditor(let id, let groupID):
            HostEditorView(hostID: id, initialGroupID: groupID)
        case .hostGroupEditor(let groupID, let parentID):
            NewGroupSheet(
                group: groupID.flatMap(app.hostLibrary.group), parentID: parentID,
                create: { group in
                    app.hostLibrary.upsert(group)
                    window.closeVaultWork()
                },
                close: window.closeVaultWork
            )
        case .forwardingEditor(let id):
            PortForwardingDetailView(ruleID: id)
        case .identityEditor(let id):
            NewIdentitySheet(
                identity: id.flatMap(app.hostLibrary.identity),
                create: { identity, password in
                    try app.hostLibrary.upsert(identity, passwordUpdate: password)
                    window.selectVaultItem(.identity(identity.id), on: .keychain)
                },
                close: window.closeVaultWork
            )
        case .generateKey:
            KeychainGenerateDetail()
        case .knownHostEditor(let id):
            KnownHostEditorView(entryID: id)
        case .sshImport(let knownHostsOnly):
            SSHImportView(knownHostsOnly: knownHostsOnly)
        case .importKey:
            KeychainImportDetail()
        case .editKey(let id):
            KeychainEditDetail(keyID: id)
        case .exportKeys(let ids):
            ExportKeyToHostsSheet(keys: ids.compactMap(app.hostLibrary.key))
        case .snippetEditor(let snippetID, let packageID):
            SnippetEditorSheet(
                snippet: snippetID.flatMap(app.hostLibrary.snippet), packageID: packageID,
                save: { snippet in
                    app.hostLibrary.upsert(snippet)
                    window.selectVaultItem(.snippet(snippet.id), on: .snippets)
                },
                close: window.closeVaultWork
            )
        case .snippetPackageEditor(let packageID, let parentID):
            SnippetPackageSheet(
                package: packageID.flatMap(app.hostLibrary.snippetPackage), parentID: parentID,
                save: { app.hostLibrary.upsert($0) }, close: window.closeVaultWork
            )
        case .snippetExecutionTargets(let request):
            SnippetExecutionTargetsView(request: request)
        }
    }
}
