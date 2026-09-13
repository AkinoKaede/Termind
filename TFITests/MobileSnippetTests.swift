import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileSnippetTests {
    @Test func legacyTimestampFallbackIsStableUntilARealEditExists() throws {
        let suiteName = "termind.snippet-timestamp-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fallback = MobileSnippetTimestamp.fallback(in: defaults)
        #expect(MobileSnippetTimestamp.fallback(in: defaults) == fallback)
        #expect(
            MobileSnippetTimestamp.resolve(modifiedAt: VaultVersion.baselineDate, fallback: fallback)
                == fallback)

        let editedAt = fallback.addingTimeInterval(60)
        #expect(MobileSnippetTimestamp.resolve(modifiedAt: editedAt, fallback: fallback) == editedAt)
    }

    @Test func snippetCardsReadCreationAndEditTimesFromTheVaultJournal() async throws {
        let app = try MobileAppModel(inMemory: true)
        var snippet = Snippet(title: "Status", body: "uptime")

        app.snippets.upsert(snippet)
        let createdAt = try #require(app.snippets.modifiedAt(for: snippet.id))
        #expect(createdAt > VaultVersion.baselineDate)
        #expect(app.snippetModifiedAt(for: snippet.id) == createdAt)

        app.snippets.upsert(snippet)
        #expect(app.snippets.modifiedAt(for: snippet.id) == createdAt)

        try await Task.sleep(for: .milliseconds(10))
        snippet.body = "uptime -p"
        app.snippets.upsert(snippet)
        let editedAt = try #require(app.snippets.modifiedAt(for: snippet.id))
        #expect(editedAt > createdAt)
        #expect(app.snippetModifiedAt(for: snippet.id) == editedAt)
    }

    @Test func packageManagementSearchAndPersistenceUseTheSharedVault() throws {
        let app = try MobileAppModel(inMemory: true)
        let root = SnippetPackage(name: "Operations")
        let child = SnippetPackage(name: "Database", parentID: root.id)
        let snippet = Snippet(title: "Status", body: "systemctl status postgresql", packageID: child.id)

        app.snippets.upsert(root)
        app.snippets.upsert(child)
        app.snippets.upsert(snippet)
        app.snippets.setSnippetPackageExpanded(false, for: root.id)

        #expect(app.snippets.searchSnippets("Operations / Database").map(\.id) == [snippet.id])
        #expect(app.snippets.snippetPackage(root.id)?.isExpanded == false)

        app.snippets.move(snippetIDs: [snippet.id], into: root.id)
        #expect(app.snippets.snippets(in: root.id).map(\.id) == [snippet.id])

        let stored = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(stored.snippets.first?.packageID == root.id)
        #expect(stored.snippetPackages.first(where: { $0.id == root.id })?.isExpanded == true)
    }

    @Test func packageDeletionCanKeepOrRemoveItsSnippetTree() throws {
        let app = try MobileAppModel(inMemory: true)
        let keptRoot = SnippetPackage(name: "Keep")
        let keptChild = SnippetPackage(name: "Child", parentID: keptRoot.id)
        let kept = Snippet(title: "Kept", body: "uptime", packageID: keptChild.id)
        app.snippets.upsert(keptRoot)
        app.snippets.upsert(keptChild)
        app.snippets.upsert(kept)

        app.snippets.delete(snippetPackageID: keptRoot.id, keepSnippets: true)
        #expect(app.snippets.snippets(in: nil).map(\.id) == [kept.id])
        #expect(app.snippets.snippetPackages.isEmpty)

        let removedRoot = SnippetPackage(name: "Remove")
        let removed = Snippet(title: "Removed", body: "pwd", packageID: removedRoot.id)
        app.snippets.upsert(removedRoot)
        app.snippets.upsert(removed)
        app.snippets.delete(snippetPackageID: removedRoot.id, keepSnippets: false)

        #expect(!app.snippets.snippets.contains(where: { $0.id == removed.id }))
        #expect(try HostPersistence(context: ModelContext(app.container)).load().snippets.map(\.id) == [kept.id])
    }

    @Test func duplicatePreservesContentAndTargetsButGetsAStableNewIdentity() {
        let hostID = UUID()
        let packageID = UUID()
        let original = Snippet(
            title: "Deploy", body: "deploy --safe", packageID: packageID,
            targetHostIDs: [hostID], sortIndex: 42)

        let copy = original.duplicated()

        #expect(copy.id != original.id)
        #expect(copy.title == "Deploy Copy")
        #expect(copy.body == original.body)
        #expect(copy.packageID == packageID)
        #expect(copy.targetHostIDs == [hostID])
        #expect(copy.sortIndex == 0)
    }

    @Test func executionDecisionChoosesHostsAndConfirmsDestructiveScripts() {
        let first = UUID()
        let second = UUID()
        let safe = Snippet(title: "Status", body: "uptime", targetHostIDs: [first])
        let destructive = Snippet(title: "Erase", body: "rm -rf /", targetHostIDs: [first, second])

        #expect(
            MobileSnippetOperations.executionDecision(
                for: safe, hostIDs: [], requiresHostSelection: false) == .chooseHosts)
        #expect(
            MobileSnippetOperations.executionDecision(
                for: safe, hostIDs: [first], requiresHostSelection: true) == .chooseHosts)
        #expect(
            MobileSnippetOperations.executionDecision(
                for: safe, hostIDs: [first], requiresHostSelection: false) == .execute([first]))
        #expect(
            MobileSnippetOperations.executionDecision(
                for: destructive, hostIDs: [first, second], requiresHostSelection: false)
                == .confirmDestructive([first, second]))
    }

    @Test func executionCreatesIndependentWorkspacesInVaultOrderWithoutChangingTargets() throws {
        let app = try MobileAppModel(inMemory: true)
        let first = Host(name: "First", host: "first.example.invalid")
        let second = Host(name: "Second", host: "second.example.invalid")
        app.library.upsert(first)
        app.library.upsert(second)
        let snippet = Snippet(title: "Status", body: "uptime", targetHostIDs: [first.id])
        app.snippets.upsert(snippet)

        let opened = app.execute(snippet, on: [second.id, first.id, second.id])
        defer { for id in opened { app.close(id) } }

        #expect(opened.count == 2)
        #expect(app.workspaces.suffix(2).map(\.descriptor.hostID) == [first.id, second.id])
        #expect(app.workspaces.suffix(2).allSatisfy { $0.descriptor.kind == .ssh })
        #expect(app.workspaces.suffix(2).allSatisfy { $0.pendingInitialCommand == snippet.body })
        #expect(app.snippets.snippets.first?.targetHostIDs == [first.id])
        let connectionHistory = app.connectionHistory.entries()
        #expect(connectionHistory.count == 2)
        #expect(Set(connectionHistory.map(\.hostID)) == Set([first.id, second.id]))
        #expect(connectionHistory.allSatisfy { $0.kind == .ssh })
        #expect(!app.pro.isPaywallPresented)
    }

    @Test func sceneExecutionSelectsTheFirstCreatedWorkspaceAndPreservesThePendingCommand() throws {
        let app = try MobileAppModel(inMemory: true)
        let first = Host(name: "First", host: "first.example.invalid")
        let second = Host(name: "Second", host: "second.example.invalid")
        app.library.upsert(first)
        app.library.upsert(second)
        let scene = MobileSceneModel(app: app)
        let snippet = Snippet(title: "Status", body: "uptime")

        scene.execute(snippet, on: [first.id, second.id])
        defer { app.closeAll() }

        #expect(scene.selectedDestination == .workspaces)
        #expect(scene.workspaceID == nil)
        scene.activatePendingWorkspace()
        #expect(scene.workspaceID == app.workspaces.first?.id)
        #expect(app.workspaces.map(\.pendingInitialCommand) == [snippet.body, snippet.body])
    }

    @Test func hostSelectionStagesExecutionOnlyAfterItsSheetDismisses() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/Snippets/MobileSnippetsView.swift"),
            encoding: .utf8)
        let sheet = try #require(
            source.components(
                separatedBy: ".sheet(item: $targetRequest, onDismiss: completeTargetSelection)"
            ).last?.components(separatedBy: ".confirmationDialog(").first)
        let completion = try #require(
            source.components(separatedBy: "private func completeTargetSelection()").last?
                .components(separatedBy: "private func performExecution").first)

        #expect(sheet.contains("pendingTargetExecution = ExecutionRequest"))
        #expect(!sheet.contains("stageExecution("))
        #expect(completion.contains("stageExecution(snippetID: request.snippetID, hostIDs: request.hostIDs)"))
    }

    @Test func initialCommandIsLaunchOnlyAndConsumedAtMostOnce() throws {
        let descriptor = MobileWorkspaceDescriptor(hostID: UUID(), title: "Server", kind: .ssh)
        let workspace = MobileWorkspace(
            descriptor: descriptor, hosts: HostLibraryModel(), initialCommand: "uname -a")

        #expect(workspace.pendingInitialCommand == "uname -a")
        #expect(workspace.consumePendingInitialCommand() == "uname -a")
        #expect(workspace.consumePendingInitialCommand() == nil)

        let separateWorkspace = MobileWorkspace(descriptor: descriptor, hosts: HostLibraryModel())
        #expect(separateWorkspace.pendingInitialCommand == nil)
    }
}
