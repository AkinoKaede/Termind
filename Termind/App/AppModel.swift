import Foundation

/// The ways a host can be opened. Centralised so the sidebar, the tab bar's `+`
/// menu, and the menu bar all take the same code path — including the bookkeeping
/// (mark as recently used, flip the status dot) that is easy to forget in one of
/// three places.
/// There is no "open into the current split" here, deliberately. A Workspace is
/// assembled from things already open — drag one tab onto another — so opening a
/// host never has to know about layout, and a host you have never opened can
/// never appear welded into whatever tab happened to be front.
/// Where a batch of hosts lands: a tab each, or one Workspace holding all of
/// them. Bringing a dozen machines up is usually so you can *watch* them, and
/// watching them means having them on screen at once.
nonisolated enum BatchLayout: Hashable, Sendable {
    case separateTabs
    case oneWorkspace
}

nonisolated enum HostOpenTarget: Hashable, Sendable {
    case sshSession
    case sftpSession
}

/// A destination typed into Welcome. The username belongs to this one attempt
/// until the user explicitly saves it; keeping it beside the Host avoids
/// inventing a persisted Identity just because somebody typed `user@host`.
nonisolated struct QuickConnectTarget: Hashable, Sendable {
    var host: Host
    var username: String?

    var loginAddress: String {
        guard let username, !username.isEmpty else { return host.displayAddress }
        return "\(username)@\(host.displayAddress)"
    }
}

/// App-wide state shared by every window: the saved hosts, and the one code path
/// for opening them.
///
/// Everything the user can have in a *different* state in a second window —
/// tabs, sidebar selection, search text, Sidebar visibility — lives on
/// `WindowModel` instead.
@Observable
final class AppModel {
    private final class WeakWindow {
        weak var value: WindowModel?
        init(_ value: WindowModel) { self.value = value }
    }

    let hosts: HostStore
    let commandHistory: CommandHistoryStore
    /// Repository-backed projection used by newly migrated features. HostStore
    /// remains temporarily available until all legacy features have moved.
    let hostLibrary: HostLibraryModel
    let commands = AppCommandRegistry()
    let connections: RemoteConnectionCoordinator
    let hostRepository: any HostRepository
    let forwarding: PortForwardingController
    let sftpTransfers: SFTPTransferCoordinator
    /// Providers, models, role assignments, MCP servers.
    ///
    /// Its own store rather than more fields on `HostStore`: that one is about
    /// machines you connect to, this one about endpoints you spend a key at.
    /// See `AIStore`.
    let ai: AIStore
    let commandComposer: CommandComposerController
    /// Names conversations for the chat list. Held as the protocol, not the
    /// concrete controller, so a test can watch the trigger without a provider.
    var conversationTitles: any ConversationTitling
    /// One app-wide microphone owner. Keeping this above individual composers
    /// prevents two windows from installing competing audio taps.
    let speechTranscription: SpeechTranscriptionCoordinator
    /// The one set of conversations every window navigates. See
    /// `AssistantConversationStore`.
    private let assistantConversations = AssistantConversationStore()
    private let agentRunRepository: any AgentRunPersisting
    private let agentHosts: AgentHostResolver
    private let agentConnections: AgentConnectionPool
    private let outboxRunner: OutboxRunner?
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var deletedAgentConversationIDs = Set<UUID>()
    /// Conversations already handed to the summarizer. Titling is once per
    /// conversation, and every run re-arms the hook that would do it.
    private var titledConversationIDs = Set<UUID>()

    init(
        hosts: HostStore, ai: AIStore = AIStore(),
        commandHistory: CommandHistoryStore = CommandHistoryStore(),
        dependencies: AppDependencies? = nil,
        speechTranscription: SpeechTranscriptionCoordinator? = nil
    ) {
        let dependencies = dependencies ?? .legacy(hosts: hosts)
        let connectionCoordinator = dependencies.connectionCoordinator
        self.hosts = hosts
        self.commandHistory = commandHistory
        connections = connectionCoordinator
        agentRunRepository = dependencies.agentRunRepository ?? InMemoryAgentRunRepository()
        agentHosts = AgentHostResolver(store: hosts)
        let agentHostResolver = agentHosts
        agentConnections = AgentConnectionPool(
            configuration: { try await agentHostResolver.configuration(for: $0) },
            routeFingerprint: { try await agentHostResolver.routeFingerprint(for: $0) },
            openExec: { try await connectionCoordinator.connectExec(using: $0) },
            openSFTP: { try await connectionCoordinator.connectSFTP(using: $0) }
        )
        hostRepository = dependencies.hostRepository
        hostLibrary = HostLibraryModel(repository: dependencies.hostRepository)
        forwarding = PortForwardingController(hosts: hosts)
        sftpTransfers = SFTPTransferCoordinator(
            store: hosts,
            clientFactory: { connectionCoordinator.makeSFTPClient() }
        )
        self.ai = ai
        commandComposer = CommandComposerController(ai: ai)
        conversationTitles = ConversationTitleController(ai: ai)
        self.speechTranscription =
            speechTranscription
            ?? SpeechTranscriptionCoordinator(
                service: AppleSpeechTranscriptionService(audioInput: MacOSSpeechAudioInput())
            )
        outboxRunner = dependencies.outboxRunner
        agentHosts.configureTemporaryTargets(
            targets: { [weak self] in self?.temporaryAgentTargets() ?? [] },
            configuration: { [weak self] hostID in
                self?.temporaryAgentConfiguration(for: hostID)
            }
        )
        hosts.willDeleteHost = { [weak forwarding, agentConnections] hostID, ruleIDs in
            forwarding?.stop(ruleIDs)
            // Not a `HostDeletionOutbox` step like the others: a live socket
            // cannot outlive the process, so there is nothing to replay after a
            // crash and nothing to make durable.
            Task { await agentConnections.disconnect(hostID: hostID) }
        }
        hosts.willDeletePortForwardings = { [weak forwarding] ruleIDs in
            forwarding?.stop(ruleIDs)
        }
        hosts.didPersistCore = { [weak repository = dependencies.hostRepository] in
            try? repository?.refresh()
        }
        if let outboxRunner {
            outboxRunner.register(
                RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.closeWorkspaces) {
                    [weak self] deletion in
                    self?.closeWorkspaces(for: deletion.hostID)
                }
            )
            outboxRunner.register(
                RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.cancelTransfers) {
                    [weak self] deletion in
                    self?.sftpTransfers.cancelAll(for: deletion.hostID)
                }
            )
            outboxRunner.register(
                RuntimeHostDeletionHandler(handlerID: HostDeletionOutbox.stopForwardings) {
                    [weak self] deletion in
                    self?.forwarding.stop(deletion.forwardingRuleIDs)
                }
            )
            outboxRunner.register(
                RepositoryHostDeletionHandler(
                    handlerID: HostDeletionOutbox.clearReferences,
                    repository: hostRepository
                )
            )
            outboxRunner.register(
                RepositoryHostDeletionHandler(
                    handlerID: HostDeletionOutbox.finalize,
                    repository: hostRepository
                )
            )
            outboxRunner.start()
        }
    }

    func sendAgentDraft(_ conversation: ConversationModel, context: SessionContext = .none) {
        let draft = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        // The *returned* text, not `draft`: attachments are folded in there, and
        // running on the pre-fold string would show the model a turn that does
        // not match the one the conversation recorded.
        let prompt = conversation.appendUserTurn(draft)
        conversation.draft = ""
        startAgentRun(conversation, prompt: prompt, context: context)
    }

    func startAgentRun(
        _ conversation: ConversationModel,
        prompt: String? = nil,
        context: SessionContext = .none
    ) {
        let userPrompt = prompt
            ?? conversation.messages.last(where: { $0.role == .user })?.text
            ?? ""
        guard !userPrompt.isEmpty else { return }
        guard let chat = ai.resolve(conversation: conversation.model) else {
            conversation.messages.append(ChatMessage(
                role: .assistant, text: String(localized: "No Chat model is configured.")
            ))
            return
        }
        let credentialRef = chat.provider.usesVertex && chat.provider.kind == .google
            ? chat.provider.vertex.credentialRef : chat.provider.credentialRef
        guard let secret = ai.secret(for: credentialRef), !secret.isEmpty else {
            conversation.messages.append(ChatMessage(
                role: .assistant, text: String(localized: "The Chat model has no available credential.")
            ))
            return
        }

        let mode = ai.resolve(conversation: conversation.permissionMode)
        let searchPlan = webSearchPlan(model: chat.model, provider: chat.provider)
        let model = AgentProviderClient(
            provider: chat.provider, model: chat.model, secret: secret,
            reasoning: conversation.reasoningEffort,
            webSearch: searchPlan.isNative
        )
        let reviewer: (any SecurityReviewing)? = {
            guard mode == .approveForMe, let review = ai.resolve(.securityReview) else { return nil }
            let ref = review.provider.usesVertex && review.provider.kind == .google
                ? review.provider.vertex.credentialRef : review.provider.credentialRef
            guard let reviewSecret = ai.secret(for: ref), !reviewSecret.isEmpty else { return nil }
            let reasoning = SecurityReviewClient.preferredReasoning(
                model: review.model, provider: review.provider
            )
            return SecurityReviewClient(model: AgentProviderClient(
                provider: review.provider, model: review.model, secret: reviewSecret,
                reasoning: reasoning
            ))
        }()
        // Weakly, all three times. The conversation owns the runtime, the
        // runtime owns the broker and the interaction handler, and both of those
        // used to own the conversation back — so every chat that had ever run an
        // agent stayed alive, with its runtime, for the life of the process.
        // A conversation that is gone denies and cancels: fail closed.
        let approval = AgentApprovalBroker(
            reviewer: reviewer,
            manualApproval: { [weak conversation] request in
                guard let conversation else {
                    return .deny(String(localized: "The conversation was closed before this action was approved."))
                }
                return await conversation.requestApproval(request)
            },
            event: { [agentRunRepository, weak conversation] event in
                Task {
                    if let runID = event.associatedRunID {
                        try? await agentRunRepository.record(event, runID: runID)
                    }
                    await MainActor.run { conversation?.handle(event) }
                }
            }
        )

        var tools: [AnyAgentTool] = []
        if chat.model.abilities.contains(.toolCall) {
            tools = AgentBuiltInTools.make(
                hosts: agentHosts, connections: agentConnections,
                search: searchPlan.local
            )
            let servers = ai.mcpServers.filter(\.isEnabled).map { server in
                (server: server, bearerToken: ai.secret(for: server.credentialRef))
            }
            tools += AgentMCPTools.make(servers: servers)
        }
        let runtime = AgentRuntime(
            model: model, tools: tools, approval: approval,
            repository: agentRunRepository,
            userInteraction: WeakAgentUserInteraction(conversation)
        )
        // No second Shell Integration gate here. `Pane.remoteSystemInfo` already
        // withholds the probe when the setting is off, and `context` is the same
        // value the chips were drawn from — so what is shown and what is sent
        // cannot disagree.
        conversation.start(runtime: runtime, request: AgentRunRequest(
            conversationID: conversation.id, prompt: userPrompt,
            permissionMode: mode, priorMessages: conversation.pendingPriorMessages,
            sessionContext: context
        ))
        scheduleTitle(for: conversation)
    }

    /// Which of the two web-search paths this turn gets, resolved once so the
    /// request body and the tool list cannot disagree.
    ///
    /// Native wins where it exists. It searches better than a snippet API can,
    /// costs no second key, and needs no round trip through Termind — the model
    /// simply knows things. What it gives up is visibility, which
    /// `AgentRuntime.recordNativeWebSearch` buys back after the fact.
    ///
    /// Exactly one path is ever live. Offering both would put two tools in
    /// front of the model for one job and leave it to guess which, and the
    /// guess would decide whether the search shows up as a card beforehand or a
    /// record afterwards.
    private func webSearchPlan(
        model: AIModel, provider: ModelProvider
    ) -> (isNative: Bool, local: WebSearchClient?) {
        guard SettingsKey.isWebSearchEnabled else { return (false, nil) }
        if SettingsKey.isBuiltInWebSearchEnabled,
            provider.supportsNativeWebSearch(model: model)
        {
            return (true, nil)
        }
        let defaults = UserDefaults.standard
        let backend = SearchBackend(
            rawValue: defaults.string(forKey: SettingsKey.webSearchBackend) ?? ""
        ) ?? .default
        let client = WebSearchClient(
            backend: backend,
            baseURL: defaults.string(forKey: SettingsKey.webSearchBaseURL) ?? "",
            apiKey: ai.secret(
                for: defaults.string(forKey: SettingsKey.webSearchCredentialRef) ?? ""
            ) ?? ""
        )
        // A keyed backend with no key registers nothing rather than a tool that
        // fails on first use — see `AgentBuiltInTools.make(search:)`.
        return (false, client.isConfigured ? client : nil)
    }

    /// Arms the one-shot summary for this conversation.
    ///
    /// Titling is deliberately once per conversation, not per run: a chat list
    /// whose rows rewrite themselves as the conversation grows is harder to scan
    /// than one whose rows stay put. `titledConversationIDs` is what makes the
    /// second run a no-op even though every run re-arms the hook.
    private func scheduleTitle(for conversation: ConversationModel) {
        conversation.runDidFinish = { [weak self, weak conversation] in
            guard let self, let conversation,
                let context = Self.titleContext(for: conversation),
                !titledConversationIDs.contains(conversation.id)
            else { return }
            titledConversationIDs.insert(conversation.id)
            Task { [weak self, weak conversation] in
                guard let self else { return }
                guard let title = try? await conversationTitles.summarize(context),
                    let conversation
                else { return }
                conversation.title = title
                try? await agentRunRepository.setTitle(title, conversationID: conversation.id)
            }
        }
    }

    /// The opening exchange, if this conversation has one worth naming.
    ///
    /// Read from `transcript`, not `messages`. A run that failed puts its reason
    /// in the visible list alone, so gating on `messages` would happily title a
    /// conversation "The Chat model has no available credential."
    ///
    /// Gated on there being a reply rather than on the run having *completed*,
    /// so a run the user stopped after a full first answer still gets a title
    /// instead of staying labelled by its opening line forever.
    static func titleContext(for conversation: ConversationModel) -> ConversationTitleContext? {
        guard conversation.title == nil,
            let user = conversation.transcript.first(where: { $0.role == .user })?.text,
            let assistant = conversation.transcript.first(where: {
                $0.role == .assistant && !$0.text.isEmpty
            })?.text
        else { return nil }
        return ConversationTitleContext(
            firstUserMessage: user, firstAssistantMessage: assistant
        )
    }

    func registerWindow(_ window: WindowModel) {
        windows = windows.filter { $0.value.value != nil }
        windows[ObjectIdentifier(window)] = WeakWindow(window)
        window.commandHistoryStore = commandHistory
        window.assistantLibrary.adopt(assistantConversations)
        window.assistantConversationDeletionHandler = { [weak self] id in
            self?.deleteAgentConversation(id)
        }
        Task { [agentRunRepository, weak window, weak self] in
            guard let restored = try? await agentRunRepository.loadConversations() else { return }
            let visible = restored.filter {
                self?.deletedAgentConversationIDs.contains($0.id) != true
            }
            window?.assistantLibrary.restore(visible)
        }
    }

    func shellIntegrationPreferenceDidChange(isEnabled: Bool) {
        windows = windows.filter { $0.value.value != nil }
        for window in windows.values.compactMap(\.value) {
            for sshSession in window.tabs.flatMap(\.panes).compactMap(\.sshSession) {
                sshSession.applyShellIntegrationPreference(isEnabled: isEnabled)
            }
            window.refreshSessionContext()
        }
    }

    private func deleteAgentConversation(_ id: UUID) {
        deletedAgentConversationIDs.insert(id)
        titledConversationIDs.remove(id)
        windows = windows.filter { $0.value.value != nil }
        for window in windows.values.compactMap(\.value) {
            window.assistantLibrary.delete(id)
            if window.sidebar.assistantConversationID == id {
                window.sidebar.assistantConversationID = nil
            }
        }
        Task { [agentRunRepository] in
            try? await agentRunRepository.deleteConversation(id)
        }
    }

    func requestHostDeletion(_ hostID: Host.ID) {
        do {
            try hostRepository.requestHostDeletion(hostID)
            commandHistory.clear(for: hostID)
            hosts.projectHostDeletion(hostID)
        } catch {
            hosts.reportStorageError(error)
        }
    }

    private func closeWorkspaces(for hostID: Host.ID) {
        windows = windows.filter { $0.value.value != nil }
        for window in windows.values.compactMap(\.value) {
            window.closeWorkspaces(for: hostID)
        }
    }

    private func temporaryAgentTargets() -> [AgentHostTarget] {
        windows = windows.filter { $0.value.value != nil }
        var seen = Set<UUID>()
        return windows.values.compactMap(\.value).flatMap(\.tabs).flatMap(\.panes)
            .compactMap(\.sshSession).compactMap(\.agentTemporaryTarget)
            .filter { seen.insert($0.id).inserted }
    }

    private func temporaryAgentConfiguration(
        for hostID: UUID
    ) -> SSHConnectionConfiguration? {
        windows = windows.filter { $0.value.value != nil }
        return windows.values.compactMap(\.value).flatMap(\.tabs).flatMap(\.panes)
            .compactMap(\.sshSession)
            .first { $0.hostID == hostID && $0.agentTemporaryTarget != nil }?
            .agentConnectionConfiguration
    }

    /// Starts teardown without waiting for network peers. AppKit's termination
    /// path runs on the main thread, so awaiting SSH/SFTP shutdown here can make
    /// ⌘Q appear hung when a peer is slow or unreachable.
    func shutdownForTermination() {
        speechTranscription.cancelAll()
        let liveWindows = windows.values.compactMap(\.value)
        windows.removeAll()
        for window in liveWindows { window.closeAll() }
        sftpTransfers.cancelAll()
        forwarding.stopAll()
        Task { [agentConnections] in await agentConnections.closeAll() }
        outboxRunner?.stop()
    }

    /// Opens a host in the given window, handing back the tab it landed in.
    ///
    /// The initial status flip is optimistic; once the terminal appears, its SSH
    /// session reports the authoritative state back to `HostStore`.
    ///
    /// The return value exists for `open(_:as:in:)`'s plural form, which has to
    /// know which tab was first. Discardable because nearly every caller opens
    /// one host and has nothing to decide afterwards.
    @discardableResult
    func open(_ host: Host, as target: HostOpenTarget, in window: WindowModel) -> Workspace {
        beginOpening(host, as: target)

        switch target {
        case .sshSession: return window.openSSHSession(host: host)
        case .sftpSession: return window.openSFTPSession(host: host)
        }
    }

    /// Opens an unsaved Welcome destination without putting it into SwiftData.
    /// Its username travels with the SSH session and seeds the credential
    /// prompt when there is no saved Identity to resolve.
    @discardableResult
    func openQuickConnect(_ target: QuickConnectTarget, in window: WindowModel) -> Workspace {
        hosts.setStatus(.connecting, for: target.host.id)
        return window.openSSHSession(host: target.host, usernameHint: target.username)
    }

    /// Turns one Welcome destination into an ordinary saved Host. A typed
    /// username is saved as an Identity only when no existing Identity was
    /// resolved for it; authentication can then be completed by the session's
    /// Continue and Save prompt.
    @discardableResult
    func saveQuickConnect(_ target: QuickConnectTarget) -> Host {
        var host = target.host
        if host.identityID == nil,
            let username = target.username?.trimmingCharacters(in: .whitespaces),
            !username.isEmpty
        {
            let identity = Identity(name: username, username: username)
            hosts.upsert(identity)
            host.identityID = identity.id
        }
        hosts.upsert(host)
        return host
    }

    /// Mark as recently used, and flip the status dot.
    ///
    /// Its own method because three code paths now open hosts — one, a batch of
    /// tabs, and a batch into one Workspace — and *where it lands* is the only
    /// thing that should differ between them. Inlining this was fine while there
    /// were two.
    private func beginOpening(_ host: Host, as target: HostOpenTarget) {
        hosts.markUsed(host.id, at: Date())
        switch target {
        case .sshSession:
            hosts.setStatus(.connecting, for: host.id)
        case .sftpSession:
            break
        }
    }

    /// Batch Startup, in either of its two shapes.
    ///
    /// The tabs path is a loop over the singular `open` rather than its own code
    /// path; the Workspace path cannot be, since the whole point is that it makes
    /// one tab. What both share is `beginOpening`, so the bookkeeping cannot
    /// drift between them.
    ///
    /// In the tabs case each `open` selects the tab it made, which would leave
    /// the *last* host in front — the one furthest from where the eye started.
    /// Landing on the first instead matches the order the list was read and
    /// ticked in, and the rest are a ⌃⇥ away.
    func open(
        _ hosts: [Host],
        as target: HostOpenTarget,
        layout: BatchLayout = .separateTabs,
        in window: WindowModel
    ) {
        switch layout {
        case .separateTabs:
            let opened = hosts.map { open($0, as: target, in: window) }
            if let first = opened.first { window.select(first.id) }
        case .oneWorkspace:
            for host in hosts { beginOpening(host, as: target) }
            window.openWorkspace(hosts, as: target)
        }
    }

    /// Turns Snippet execution into ordinary visible sessions rather than a
    /// hidden job. `overrideHostIDs` powers Execute on Hosts; `fallbackHostIDs`
    /// is used only by snippets whose saved target list is empty.
    func execute(
        _ snippets: [Snippet], overrideHostIDs: [Host.ID]? = nil,
        fallbackHostIDs: [Host.ID]? = nil, in window: WindowModel
    ) {
        var opened: [Workspace] = []
        for snippet in snippets {
            let ids =
                overrideHostIDs
                ?? (snippet.targetHostIDs.isEmpty
                    ? (fallbackHostIDs ?? []) : snippet.targetHostIDs)
            let wanted = Set(ids)
            let targets = hosts.searchHosts("").filter { wanted.contains($0.id) }
            guard !targets.isEmpty else { continue }
            for host in targets { beginOpening(host, as: .sshSession) }
            if let workspace = window.openSnippetWorkspace(
                hosts: targets, command: snippet.body
            ) {
                opened.append(workspace)
            }
        }
        if let first = opened.first { window.select(first.id) }
    }

    /// ⌘T, the window toolbar's `+`, the tab bar's `+`, and Welcome. Raises the
    /// host chooser.
    ///
    /// Termind has no local shell, so "new session" has to name a machine. A sheet
    /// rather than the Hosts page: the page is a manager — it edits, groups, and
    /// deletes — and sending every ⌘T there meant navigating away from whatever
    /// was on screen just to ask one question.
    ///
    /// The sheet starts with nothing selected, deliberately. A command that
    /// connects to a selection made earlier, on another screen, is how a
    /// keystroke meant for staging lands on production. ⌘T never connects on its
    /// own; it puts the question up, and Return answers it.
    func connect(in window: WindowModel) {
        window.hostChooser = .connect
    }

    /// The Batch Startup row at the foot of the sidebar's Sessions section. The
    /// same sheet again, in its multi-select
    /// mode — see `HostChooserPurpose`.
    ///
    /// The sidebar and Welcome page raise this chooser. It is not in the File
    /// menu or the tab bar's `+`: bringing up a dozen machines is a deliberate
    /// act, kept on surfaces that name Batch Startup directly.
    func batchStartup(in window: WindowModel) {
        window.hostChooser = .batchStartup
    }

    /// Parses `user@host:port` typed into the quick-connect field. Returns nil
    /// when the input is not a plausible destination, so the field can stay
    /// quiet rather than flashing an error on every keystroke.
    ///
    /// A typed login name is resolved when exactly one saved Identity uses it.
    /// It also remains on the transient target so `a@b` always connects as `a`,
    /// even when no Identity exists yet. Nothing is persisted until Save or
    /// Continue and Save is chosen.
    func parseQuickConnect(_ input: String) -> QuickConnectTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        var username: String?
        var remainder = trimmed[...]
        if let at = trimmed.lastIndex(of: "@") {
            let typed = String(trimmed[trimmed.startIndex..<at])
            guard !typed.isEmpty else { return nil }
            username = typed
            remainder = trimmed[trimmed.index(after: at)...]
        }

        guard let (host, port) = Self.splitPort(String(remainder)) else { return nil }
        guard !host.isEmpty, host.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }

        // Ambiguity is left unresolved rather than guessed at: two identities
        // named `root` differ in which key they present, and picking one for the
        // user would be picking a credential for them.
        let matches = username.map { name in hosts.identities.filter { $0.username == name } }
        let identityID = matches?.count == 1 ? matches?.first?.id : nil

        return QuickConnectTarget(
            host: Host(name: host, host: host, port: port, identityID: identityID),
            username: username
        )
    }

    /// Splits `host`, `host:port`, or `[v6]:port` into its two halves.
    ///
    /// The bracket case is the reason this is not one `lastIndex(of: ":")`: a bare
    /// IPv6 literal is *all* colons, and naive splitting turns `2001:db8::1` into
    /// the host `2001:db8:` on port 1 — a plausible-looking address that is not
    /// the one anybody typed. So brackets mean "port follows", more than one colon
    /// without them means "this is IPv6, no port".
    private static func splitPort(_ input: String) -> (host: String, port: Int)? {
        if input.hasPrefix("[") {
            guard let close = input.firstIndex(of: "]") else { return nil }
            let host = String(input[input.index(after: input.startIndex)..<close])
            let rest = input[input.index(after: close)...]
            if rest.isEmpty { return (host, 22) }
            guard rest.hasPrefix(":"), let port = parsePort(rest.dropFirst()) else { return nil }
            return (host, port)
        }

        let colons = input.filter { $0 == ":" }.count
        switch colons {
        case 0:
            return (input, 22)
        case 1:
            let parts = input.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let port = parsePort(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default:
            return (input, 22)
        }
    }

    private static func parsePort(_ text: Substring) -> Int? {
        guard let value = Int(text), (1...65_535).contains(value) else { return nil }
        return value
    }
}
