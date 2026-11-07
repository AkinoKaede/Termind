// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct ModelSpecificationPersistenceTests {
    @Test func newNonChatTypesHaveASafeLegacyProjection() throws {
        var model = AIModel(id: "speech")
        model.specification.type = "speech"
        let wire = SyncedAIModel(model)
        #expect(wire.kind == AIModel.Kind.classifier.rawValue)
        #expect(wire.value.kind == .speech)
        let row = PersistentAIModel(model, providerID: UUID(), sortIndex: 0)
        #expect(row.value.kind == .classifier)
        let native = try PersistentAIModelSpecification(modelRecordID: row.recordID, specification: model.specification)
        var restored = row.value
        native.apply(to: &restored)
        #expect(restored.kind == .speech)
        #expect(ModelProvider(name: "Speech", models: [restored]).assistantModels.isEmpty)
    }

    @Test func compactionUsesTheSmallerPositiveInputLimitWithoutChangingDisplayedContext() {
        var model = AIModel(id: "limited", contextLength: 1_050_000)
        model.specification.limit.input = 922_000
        #expect(model.compactionContextWindow == 922_000)
        #expect(model.contextLength == 1_050_000)
        model.specification.limit.input = 2_000_000
        #expect(model.compactionContextWindow == 1_050_000)
        model.contextLength = nil
        #expect(model.compactionContextWindow == 2_000_000)
        model.specification.limit.input = 0
        #expect(model.compactionContextWindow == nil)
    }

    @Test func syncKeepsNativeFieldsAndReadsLegacyPayloads() throws {
        let original = try model()
        let data = try JSONEncoder().encode(SyncedAIModel(original))
        let decoded = try JSONDecoder().decode(SyncedAIModel.self, from: data).value
        #expect(decoded.specification == original.specification)
        #expect(decoded.reasoningProfile == original.reasoningProfile)
        #expect(!decoded.isShownInAssistant)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "specification")
        let restored = try JSONDecoder().decode(
            SyncedAIModel.self, from: JSONSerialization.data(withJSONObject: legacy)
        ).value
        #expect(restored.id == original.id)
        #expect(restored.input == original.input)
        #expect(restored.contextLength == original.contextLength)
        #expect(restored.reasoningProfile == original.reasoningProfile)
        #expect(restored.specification.cost.fields.isEmpty)
    }

    @Test func legacyModelSurvivesMigrationAndNativeMetadataSurvivesReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("models.store")
        let original = try model()
        let provider = ModelProvider(name: "Saved provider", credentialRef: "keychain-reference", models: [original])
        try writeHistorical(provider, to: url)
        try upgrade(provider, at: url)
        let reopened = try TermindPersistence.makeContainer(url: url)
        let store = AIPersistence(context: reopened.mainContext)
        var snapshot = try store.load()
        let restoredProvider = try #require(snapshot.providers.first)
        let restored = try #require(restoredProvider.models.first)
        #expect(restoredProvider.credentialRef == "keychain-reference")
        #expect(restored.specification == original.specification)
        #expect(restored.reasoningProfile == original.reasoningProfile)
        #expect(!restored.isShownInAssistant)
        snapshot.providers[0].models = []
        try store.save(snapshot)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PersistentAIModelSpecification>()).isEmpty)
    }

    @Test func corruptSpecificationFallsBackToHistoricalColumns() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let original = try model()
        var restored = original
        let row = try PersistentAIModelSpecification(modelRecordID: UUID(), specification: original.specification)
        row.specificationData = Data("broken".utf8)
        container.mainContext.insert(row)
        row.apply(to: &restored)
        #expect(restored == original)
    }

    private func writeHistorical(_ provider: ModelProvider, to url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV59.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.insert(
            PersistentModelProvider(provider, endpoint: ProviderEndpoint(url: ""), sortIndex: 0))
        container.mainContext.insert(PersistentAIModel(provider.models[0], providerID: provider.id, sortIndex: 0))
        try container.mainContext.save()
    }

    private func upgrade(_ provider: ModelProvider, at url: URL) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        let store = AIPersistence(context: container.mainContext)
        var snapshot = try store.load()
        let migrated = try #require(snapshot.providers.first?.models.first)
        #expect(migrated.id == provider.models[0].id)
        #expect(migrated.displayName == provider.models[0].displayName)
        #expect(migrated.contextLength == 272000)
        #expect(migrated.reasoningProfile == provider.models[0].reasoningProfile)
        #expect(!migrated.isShownInAssistant)
        snapshot.providers[0].models[0].specification = provider.models[0].specification
        try store.save(snapshot)
    }

    private func model() throws -> AIModel {
        let data = Data(
            #"""
            {"id":"codex-auto-review","name":"My review model","reasoning":true,"tool_call":true,
             "structured_output":true,"modalities":{"input":["text","image"],"output":["text"]},
             "limit":{"context":272000,"input":260000},"cost":{"input":0,"cache_read":0.25},
             "reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}],
             "experimental":{"future":[1,true,"keep"]},"release_date":"2026-01-01"}
            """#.utf8)
        var model = AIModel(id: "codex-auto-review", isShownInAssistant: false)
        model.specification = try JSONDecoder().decode(ModelsDevModel.self, from: data)
        model.reasoningProfile = ReasoningProfile(levels: [
            .high: ReasoningLevelMapping(isSupported: true, wireValue: "custom")
        ])
        return model
    }
}
