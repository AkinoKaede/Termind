import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain

public nonisolated struct SettingsSyncSnapshot: Sendable {
    public var configuration: AIConfigurationSnapshot
    public var skills: [AgentSkill]
    public var webSearch: AIWebSearchPreferences
    public var terminal = TerminalPreferences()
    public var ssh = SSHPreferences()
    public var sftp = SFTPPreferences()
    public var workspace = WorkspacePreferences()

    public init(
        configuration: AIConfigurationSnapshot, skills: [AgentSkill], webSearch: AIWebSearchPreferences,
        terminal: TerminalPreferences = .init(), ssh: SSHPreferences = .init(),
        sftp: SFTPPreferences = .init(), workspace: WorkspacePreferences = .init()
    ) {
        self.configuration = configuration
        self.skills = skills
        self.webSearch = webSearch
        self.terminal = terminal
        self.ssh = ssh
        self.sftp = sftp
        self.workspace = workspace
    }

    public var recordPayloads: [SettingsRecordKey: SettingsRecordPayload] {
        var payloads: [SettingsRecordPayload] = []
        for (index, provider) in configuration.providers.enumerated() {
            payloads.append(
                .provider(
                    SyncedModelProvider(
                        provider,
                        endpoint: configuration.endpoints[provider.id] ?? ProviderEndpoint(url: provider.inferenceURL),
                        sortIndex: index)))
        }
        for (index, server) in configuration.mcpServers.enumerated() {
            payloads.append(.mcpServer(SyncedMCPServer(server, sortIndex: index)))
        }
        for (index, skill) in skills.enumerated() { payloads.append(.skill(skill, sortIndex: index)) }
        for role in AIRole.allCases { payloads.append(.role(role, configuration.roles[role])) }
        payloads.append(.webSearch(webSearch))
        payloads.append(.terminal(terminal))
        payloads.append(.ssh(ssh))
        payloads.append(.sftp(sftp))
        payloads.append(.workspace(workspace))
        return Dictionary(uniqueKeysWithValues: payloads.map { ($0.key, $0) })
    }
}

/// Configuration and upload intent commit together; remote updates skip the local write path.
@MainActor
public final class SettingsSyncPersistence {
    public let context: ModelContext
    private let defaults: UserDefaults
    private let ai: AIPersistence
    private let skills: SkillPersistence
    public let journal: SettingsSyncJournal
    public var didRecordChanges: ((SettingsMutationSet) -> Void)?

    public init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
        ai = AIPersistence(context: context)
        skills = SkillPersistence(context: context)
        journal = SettingsSyncJournal(context: context)
    }

    public func prepare() throws {
        var mutations = SettingsMutationSet.empty
        try context.commit {
            mutations.keys.formUnion(try journal.migrateLegacyGuardianRole().keys)
            try journal.discardInactiveEntries()
            let previous = try load()
            mutations.keys.formUnion(try journal.bootstrapIfNeeded(previous).keys)
            // Add preferences introduced after an installed store completed its bootstrap.
            for payload in [
                SettingsRecordPayload.terminal(previous.terminal), .ssh(previous.ssh), .sftp(previous.sftp),
                .workspace(previous.workspace),
            ] {
                if try journal.envelope(for: payload.key) == nil {
                    let version = VaultVersion.baseline(writerID: try journal.state().installationID)
                    let envelope = SettingsEnvelope(key: payload.key, version: version, payload: payload)
                    context.insert(try PersistentAIConfigurationSyncEntry(envelope: envelope, needsUpload: true))
                    mutations.keys.insert(payload.key)
                }
            }
        }
        let snapshot = try load()
        mirror(snapshot.webSearch)
        snapshot.terminal.mirror(to: defaults)
        snapshot.ssh.mirror(to: defaults)
        snapshot.sftp.mirror(to: defaults)
        didRecordChanges?(mutations)
    }

    public func purgeCloudCache(
        scope: CloudSyncScope, assetCleanupKey: String? = nil
    ) throws -> (SettingsSyncSnapshot, Set<SettingsRecordKey>) {
        var removed = Set<SettingsRecordKey>()
        var snapshot = try load()
        try context.commit {
            removed = Set(
                try journal.cloudRecords().compactMap { SettingsRecordKey(recordName: $0.mutation.recordName) })
            let suppressed = try journal.purgeCloudCache()
            snapshot = try materialize()
            try ai.replace(snapshot.configuration)
            try skills.replace(snapshot.skills)
            try preferences().apply(snapshot.webSearch)
            try terminalPreferences().apply(snapshot.terminal)
            try sshPreferences().apply(snapshot.ssh)
            try sftpPreferences().apply(snapshot.sftp)
            try workspacePreferences().apply(snapshot.workspace)
            try CloudSyncSafetyStore(context: context, scope: scope).purgeScope()
            let cloud = CloudSyncRecordStateStore(context: context, scope: scope)
            try cloud.purgeScope()
            for mutation in suppressed {
                try cloud.deleted(mutation.recordName, version: mutation.version)
            }
            if let assetCleanupKey {
                try CloudSyncAssetCleanupStore(context: context).markPending(
                    scope: scope, cacheKey: assetCleanupKey)
            }
        }
        mirror(snapshot.webSearch)
        snapshot.terminal.mirror(to: defaults)
        snapshot.ssh.mirror(to: defaults)
        snapshot.sftp.mirror(to: defaults)
        return (snapshot, removed)
    }

    public func load() throws -> SettingsSyncSnapshot {
        SettingsSyncSnapshot(
            configuration: try ai.load(preservingUnresolvedReferences: true),
            skills: try skills.load(), webSearch: try preferences().value, terminal: try terminalPreferences().load(),
            ssh: try sshPreferences().load(), sftp: try sftpPreferences().load(),
            workspace: try workspacePreferences().load())
    }

    public func saveConfiguration(_ configuration: AIConfigurationSnapshot) throws {
        try saveLocal { try ai.replace(configuration) }
    }

    public func saveSkills(_ values: [AgentSkill]) throws {
        try saveLocal { try skills.replace(values) }
    }

    public func saveWebSearch(_ value: AIWebSearchPreferences) throws {
        try saveLocal { try preferences().apply(value) }
        mirror(value)
    }

    private func saveLocal(_ change: () throws -> Void) throws {
        var mutations = SettingsMutationSet.empty
        try context.commit {
            let previous = try load()
            try journal.bootstrapIfNeeded(previous)
            try change()
            mutations = try journal.recordLocalChanges(from: previous, to: load())
        }
        didRecordChanges?(mutations)
    }

    public func applyRemote(
        _ envelopes: [SettingsEnvelope], deletions: Set<SettingsRecordKey> = [],
        beforeSave: () throws -> Void = {}
    ) throws
        -> (
            snapshot: SettingsSyncSnapshot, acceptedKeys: Set<SettingsRecordKey>,
            needsUpload: Set<SettingsRecordKey>
        )
    {
        var merge = SettingsRemoteMerge()
        var snapshot = try load()
        let activeEnvelopes = envelopes.filter { $0.key.kind.participatesInSync }
        try context.commit(beforeSave: beforeSave) {
            let deleted = try journal.deletionEnvelopes(deletions)
            merge = try journal.mergeDecision(for: activeEnvelopes.filter { !deletions.contains($0.key) } + deleted)
            guard !merge.accepted.isEmpty else {
                try journal.markNeedsUpload(merge.needsUpload)
                return
            }
            try journal.acceptRemote(merge.accepted)
            // Rebuild from the complete journal, so roles arriving before providers survive.
            let existingPackages = Dictionary(
                uniqueKeysWithValues: try skills.load().compactMap { skill in
                    skill.package.map { (skill.id, $0) }
                })
            let existingProviders = Dictionary(
                uniqueKeysWithValues: snapshot.configuration.providers.map { ($0.id, $0) })
            let legacyProviderIDs = Set(
                try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()).compactMap {
                    row -> UUID? in
                    guard let envelope = row.envelope, !envelope.isDeleted,
                        case .provider(let value) = envelope.payload, value.vertex == nil
                    else { return nil }
                    return value.id
                })
            snapshot = try materialize()
            let remoteSnapshot = snapshot
            for index in snapshot.configuration.providers.indices {
                let id = snapshot.configuration.providers[index].id
                if legacyProviderIDs.contains(id), let old = existingProviders[id] {
                    snapshot.configuration.providers[index].usesVertex = old.usesVertex
                    snapshot.configuration.providers[index].vertex = old.vertex
                }
            }
            for index in snapshot.skills.indices where snapshot.skills[index].package == nil {
                snapshot.skills[index].package = existingPackages[snapshot.skills[index].id]
            }
            merge.needsUpload.formUnion(try journal.recordLocalChanges(from: remoteSnapshot, to: snapshot).keys)
            try ai.replace(snapshot.configuration)
            try skills.replace(snapshot.skills)
            try preferences().apply(snapshot.webSearch)
            try terminalPreferences().apply(snapshot.terminal)
            try sshPreferences().apply(snapshot.ssh)
            try sftpPreferences().apply(snapshot.sftp)
            try workspacePreferences().apply(snapshot.workspace)
            try journal.markNeedsUpload(merge.needsUpload)
        }
        mirror(snapshot.webSearch)
        snapshot.terminal.mirror(to: defaults)
        snapshot.ssh.mirror(to: defaults)
        snapshot.sftp.mirror(to: defaults)
        return (snapshot, Set(merge.accepted.map(\.key)), merge.needsUpload)
    }

    private func materialize() throws -> SettingsSyncSnapshot {
        let envelopes = try context.fetch(
            FetchDescriptor<PersistentAIConfigurationSyncEntry>()
        ).compactMap(\.envelope)
        let localSelection = try ai.load(preservingUnresolvedReferences: true).lastSelectedModel
        var providers: [SyncedModelProvider] = []
        var servers: [SyncedMCPServer] = []
        var skillRows: [(AgentSkill, Int)] = []
        var configuration = AIConfigurationSnapshot(
            providers: [], roles: [:], lastSelectedModel: localSelection)
        var webSearch = try preferences().value
        var terminal = try terminalPreferences().load()
        var ssh = try sshPreferences().load()
        var sftp = try sftpPreferences().load()
        var workspace = try workspacePreferences().load()
        for envelope in envelopes where envelope.isDeleted {
            switch envelope.key.kind {
            case .webSearch: webSearch = AIWebSearchPreferences()
            case .terminal: terminal = TerminalPreferences()
            case .ssh: ssh = SSHPreferences()
            case .sftp: sftp = SFTPPreferences()
            case .workspace: workspace = WorkspacePreferences()
            default: break
            }
        }
        for envelope in envelopes where !envelope.isDeleted && envelope.key.kind.participatesInSync {
            switch envelope.payload {
            case .provider(let value): providers.append(value)
            case .mcpServer(let value): servers.append(value)
            case .skill(let value, let index): skillRows.append((value, index))
            case .role(let role, let ref): configuration.roles[role] = ref
            case .selection: break
            case .webSearch(let value): webSearch = value
            case .terminal(let value): terminal = value
            case .ssh(let value): ssh = value
            case .sftp(let value): sftp = value
            case .workspace(let value): workspace = value
            case nil: break
            }
        }
        providers.sort { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        servers.sort { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        skillRows.sort { ($0.1, $0.0.id.uuidString) < ($1.1, $1.0.id.uuidString) }
        configuration.providers = providers.map(\.value)
        configuration.endpoints = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.endpoint) })
        configuration.mcpServers = servers.map(\.value)
        let deletedProviders = Set(envelopes.filter { $0.isDeleted && $0.key.kind == .provider }.map(\.key.id))
        func wasRemoved(_ ref: AIModelRef) -> Bool {
            if deletedProviders.contains(ref.modelProviderID.uuidString.lowercased()) { return true }
            guard let provider = configuration.providers.first(where: { $0.id == ref.modelProviderID }) else {
                return false
            }
            return provider.model(ref.modelID) == nil
        }
        configuration.roles = configuration.roles.filter { !wasRemoved($0.value) }
        if let ref = configuration.lastSelectedModel,
            configuration.providers.first(where: { $0.id == ref.modelProviderID })?.model(ref.modelID) == nil
        {
            configuration.lastSelectedModel = nil
        }
        return SettingsSyncSnapshot(
            configuration: configuration, skills: skillRows.map(\.0), webSearch: webSearch, terminal: terminal,
            ssh: ssh, sftp: sftp, workspace: workspace)
    }

    private func terminalPreferences() throws -> PersistentTerminalPreferences {
        if let row = try context.fetch(FetchDescriptor<PersistentTerminalPreferences>()).first {
            try TerminalFontPreferences.migrateLegacySettings(from: row.data, defaults: defaults)
            return row
        }
        try TerminalFontPreferences.migrateLegacySettings(from: nil, defaults: defaults)
        let row = try PersistentTerminalPreferences(TerminalPreferences(defaults: defaults))
        context.insert(row)
        return row
    }

    public func loadTerminal() throws -> TerminalPreferences { try terminalPreferences().load() }

    public func saveTerminal(_ value: TerminalPreferences) throws {
        try saveLocal { try terminalPreferences().apply(value) }
        value.mirror(to: defaults)
    }

    private func sshPreferences() throws -> PersistentSSHPreferences {
        if let row = try context.fetch(FetchDescriptor<PersistentSSHPreferences>()).first { return row }
        let row = try PersistentSSHPreferences(SSHPreferences(defaults: defaults))
        context.insert(row)
        return row
    }

    public func loadSSH() throws -> SSHPreferences { try sshPreferences().load() }

    public func saveSSH(_ value: SSHPreferences) throws {
        let value = value.normalized
        try saveLocal { try sshPreferences().apply(value) }
        value.mirror(to: defaults)
    }

    private func sftpPreferences() throws -> PersistentSFTPPreferences {
        if let row = try context.fetch(FetchDescriptor<PersistentSFTPPreferences>()).first { return row }
        let row = try PersistentSFTPPreferences(SFTPPreferences(defaults: defaults))
        context.insert(row)
        return row
    }

    public func loadSFTP() throws -> SFTPPreferences { try sftpPreferences().load() }

    public func saveSFTP(_ value: SFTPPreferences) throws {
        let value = value.normalized
        try saveLocal { try sftpPreferences().apply(value) }
        value.mirror(to: defaults)
    }

    private func workspacePreferences() throws -> PersistentWorkspacePreferences {
        if let row = try context.fetch(FetchDescriptor<PersistentWorkspacePreferences>()).first { return row }
        let row = try PersistentWorkspacePreferences(WorkspacePreferences())
        context.insert(row)
        return row
    }

    public func loadWorkspacePreferences() throws -> WorkspacePreferences {
        try workspacePreferences().load()
    }

    public func saveWorkspacePreferences(_ value: WorkspacePreferences) throws {
        try saveLocal { try workspacePreferences().apply(value) }
    }

    private func preferences() throws -> PersistentAIWebSearchPreferences {
        if let row = try context.fetch(FetchDescriptor<PersistentAIWebSearchPreferences>()).first { return row }
        let row = PersistentAIWebSearchPreferences(
            AIWebSearchPreferences(
                isEnabled: defaults.object(forKey: SettingsKey.webSearchEnabled) as? Bool
                    ?? SettingsKey.defaultWebSearchEnabled,
                prefersBuiltIn: defaults.object(forKey: SettingsKey.webSearchBuiltIn) as? Bool
                    ?? SettingsKey.defaultWebSearchBuiltIn))
        context.insert(row)
        return row
    }

    private func mirror(_ value: AIWebSearchPreferences) {
        defaults.set(value.isEnabled, forKey: SettingsKey.webSearchEnabled)
        defaults.set(value.prefersBuiltIn, forKey: SettingsKey.webSearchBuiltIn)
    }
}

@MainActor
public final class SyncedAIConfigurationPersistence: AIConfigurationPersisting {
    private let store: SettingsSyncPersistence
    public init(_ store: SettingsSyncPersistence) { self.store = store }
    public func load() throws -> AIConfigurationSnapshot { try store.load().configuration }
    public func save(_ snapshot: AIConfigurationSnapshot) throws { try store.saveConfiguration(snapshot) }
}

@MainActor
public final class SyncedSkillLibraryPersistence: SkillLibraryPersisting {
    private let store: SettingsSyncPersistence
    public init(_ store: SettingsSyncPersistence) { self.store = store }
    public func load() throws -> [AgentSkill] { try store.load().skills }
    public func save(_ skills: [AgentSkill]) throws { try store.saveSkills(skills) }
}

extension SettingsSyncPersistence: AIWebSearchPersisting {
    public func loadWebSearch() throws -> AIWebSearchPreferences { try load().webSearch }
}

extension SettingsSyncPersistence: TerminalPreferencesPersisting {}
extension SettingsSyncPersistence: SSHPreferencesPersisting {}
extension SettingsSyncPersistence: SFTPPreferencesPersisting {}
extension SettingsSyncPersistence: WorkspacePreferencesPersisting {}
