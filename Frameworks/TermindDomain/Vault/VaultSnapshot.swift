import Foundation

public nonisolated struct VaultSnapshot: Sendable {
    public var hosts: [Host] = []
    public var groups: [HostGroup] = []
    public var identities: [Identity] = []
    public var keys: [SSHKeyRef] = []
    public var knownHosts: [KnownHostEntry] = []
    public var snippets: [Snippet] = []
    public var snippetPackages: [SnippetPackage] = []
    public var portForwardings: [PortForwardingRule] = []
    public var workspaceTemplates: [WorkspaceTemplate] = []
    public init(
        hosts: [Host] = [], groups: [HostGroup] = [], identities: [Identity] = [], keys: [SSHKeyRef] = [],
        knownHosts: [KnownHostEntry] = [], snippets: [Snippet] = [], snippetPackages: [SnippetPackage] = [],
        portForwardings: [PortForwardingRule] = [], workspaceTemplates: [WorkspaceTemplate] = []
    ) {
        self.hosts = hosts
        self.groups = groups
        self.identities = identities
        self.keys = keys
        self.knownHosts = knownHosts
        self.snippets = snippets
        self.snippetPackages = snippetPackages
        self.portForwardings = portForwardings
        self.workspaceTemplates = workspaceTemplates
    }

}

public nonisolated struct VaultRemoteApplyResult: Sendable {
    public var snapshot: VaultSnapshot
    public var acceptedKeys: Set<VaultRecordKey>
    public var needsUpload: Set<VaultRecordKey>
    public init(snapshot: VaultSnapshot, acceptedKeys: Set<VaultRecordKey>, needsUpload: Set<VaultRecordKey>) {
        self.snapshot = snapshot
        self.acceptedKeys = acceptedKeys
        self.needsUpload = needsUpload
    }

}
