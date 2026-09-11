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

    public init(
        configuration: AIConfigurationSnapshot, skills: [AgentSkill], webSearch: AIWebSearchPreferences,
        terminal: TerminalPreferences = .init()
    ) {
        self.configuration = configuration
        self.skills = skills
        self.webSearch = webSearch
        self.terminal = terminal
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
        payloads.append(.selection(configuration.lastSelectedModel))
        payloads.append(.webSearch(webSearch))
        payloads.append(.terminal(terminal))
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
        let seeded = defaults.integer(forKey: SettingsKey.seededSkillGeneration)
        var mutations = SettingsMutationSet.empty
        try context.commit {
            if try !journal.state().bootstrapCompleted {
                let installed = try skills.load()
                let normalized = Self.normalizeBuiltIns(installed, seededGeneration: seeded)
                try skills.replace(normalized.skills)
                let snapshot = try load()
                try journal.bootstrapIfNeeded(snapshot)
                let writer = try journal.state().installationID
                for id in normalized.deleted {
                    let key = SettingsRecordKey(kind: .skill, id: id.uuidString.lowercased())
                    let envelope = SettingsEnvelope(
                        key: key, version: .baseline(writerID: writer), isDeleted: true)
                    context.insert(try PersistentAIConfigurationSyncEntry(envelope: envelope, needsUpload: true))
                }
            } else if seeded < AgentSkillLibrary.currentGeneration {
                let previous = try load()
                var installed = previous.skills
                for skill in AgentSkillLibrary.builtIns(after: seeded) {
                    let key = SettingsRecordKey(kind: .skill, id: skill.id.uuidString.lowercased())
                    if try journal.envelope(for: key) == nil { installed.append(skill) }
                }
                try skills.replace(installed)
                mutations = try journal.recordLocalChanges(from: previous, to: load())
            }
            // V14 adds Terminal preferences to stores whose V13 bootstrap is already complete.
            let terminal = SettingsRecordPayload.terminal(try terminalPreferences().load())
            if try journal.envelope(for: terminal.key) == nil {
                let version = VaultVersion.baseline(writerID: try journal.state().installationID)
                let envelope = SettingsEnvelope(key: terminal.key, version: version, payload: terminal)
                context.insert(try PersistentAIConfigurationSyncEntry(envelope: envelope, needsUpload: true))
                mutations.keys.insert(terminal.key)
            }
        }
        defaults.set(AgentSkillLibrary.currentGeneration, forKey: SettingsKey.seededSkillGeneration)
        let snapshot = try load()
        mirror(snapshot.webSearch)
        snapshot.terminal.mirror(to: defaults)
        didRecordChanges?(mutations)
    }

    public static func normalizeBuiltIns(_ installed: [AgentSkill], seededGeneration: Int)
        -> (skills: [AgentSkill], deleted: Set<UUID>)
    {
        var result = installed
        var deleted = Set<UUID>()
        let newIDs = Set(AgentSkillLibrary.builtIns(after: seededGeneration).map(\.id))
        for builtIn in AgentSkillLibrary.builtIns(after: 0) {
            let matching = result.indices.filter {
                result[$0].id == builtIn.id
                    || (result[$0].name == builtIn.name && result[$0].title == builtIn.title
                        && result[$0].summary == builtIn.summary && result[$0].body == builtIn.body)
            }
            if let first = matching.first {
                result[first].id = builtIn.id
                for index in matching.dropFirst().reversed() { result.remove(at: index) }
            } else if newIDs.contains(builtIn.id) {
                result.append(builtIn)
            } else {
                deleted.insert(builtIn.id)
            }
        }
        return (result, deleted)
    }

    public func load() throws -> SettingsSyncSnapshot {
        SettingsSyncSnapshot(
            configuration: try ai.load(preservingUnresolvedReferences: true),
            skills: try skills.load(), webSearch: try preferences().value, terminal: try terminalPreferences().load())
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

    public func applyRemote(_ envelopes: [SettingsEnvelope]) throws
        -> (
            snapshot: SettingsSyncSnapshot, acceptedKeys: Set<SettingsRecordKey>,
            needsUpload: Set<SettingsRecordKey>
        )
    {
        var merge = SettingsRemoteMerge()
        var snapshot = try load()
        try context.commit {
            merge = try journal.mergeDecision(for: envelopes)
            guard !merge.accepted.isEmpty else {
                try journal.markNeedsUpload(merge.needsUpload)
                return
            }
            try journal.acceptRemote(merge.accepted)
            // Rebuild from the complete journal, so roles arriving before providers survive.
            snapshot = try materialize()
            try ai.replace(snapshot.configuration)
            try skills.replace(snapshot.skills)
            try preferences().apply(snapshot.webSearch)
            try terminalPreferences().apply(snapshot.terminal)
            try journal.markNeedsUpload(merge.needsUpload)
        }
        mirror(snapshot.webSearch)
        snapshot.terminal.mirror(to: defaults)
        return (snapshot, Set(merge.accepted.map(\.key)), merge.needsUpload)
    }

    private func materialize() throws -> SettingsSyncSnapshot {
        let envelopes = try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()).compactMap(\.envelope)
        var providers: [SyncedModelProvider] = []
        var servers: [SyncedMCPServer] = []
        var skillRows: [(AgentSkill, Int)] = []
        var configuration = AIConfigurationSnapshot(providers: [], roles: [:])
        var webSearch = try preferences().value
        var terminal = try terminalPreferences().load()
        for envelope in envelopes where !envelope.isDeleted {
            switch envelope.payload {
            case .provider(let value): providers.append(value)
            case .mcpServer(let value): servers.append(value)
            case .skill(let value, let index): skillRows.append((value, index))
            case .role(let role, let ref): configuration.roles[role] = ref
            case .selection(let ref): configuration.lastSelectedModel = ref
            case .webSearch(let value): webSearch = value
            case .terminal(let value): terminal = value
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
        if let ref = configuration.lastSelectedModel, wasRemoved(ref) { configuration.lastSelectedModel = nil }
        return SettingsSyncSnapshot(
            configuration: configuration, skills: skillRows.map(\.0), webSearch: webSearch, terminal: terminal)
    }

    private func terminalPreferences() throws -> PersistentTerminalPreferences {
        if let row = try context.fetch(FetchDescriptor<PersistentTerminalPreferences>()).first { return row }
        let row = try PersistentTerminalPreferences(TerminalPreferences(defaults: defaults))
        context.insert(row)
        return row
    }

    public func loadTerminal() throws -> TerminalPreferences { try terminalPreferences().load() }

    public func saveTerminal(_ value: TerminalPreferences) throws {
        try saveLocal { try terminalPreferences().apply(value) }
        value.mirror(to: defaults)
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
