// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindPresentation
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileCardTests {
    @Test(arguments: [
        (CGFloat(0), 1), (CGFloat(63), 1), (CGFloat(320), 3), (CGFloat(361), 4),
        (CGFloat(427), 4), (CGFloat(428), 5), (CGFloat(736), 8),
        (CGFloat(992), 11), (CGFloat(1334), 15),
    ])
    func compactGridFitsColumnsToAvailableWidth(width: CGFloat, expectedColumns: Int) {
        #expect(
            MobileCardLayout.columns(width: width, accessibilitySize: false, compact: true) == expectedColumns)
    }

    @Test func compactGridRespectsScaledCardWidth() {
        #expect(
            MobileCardLayout.columns(width: 736, accessibilitySize: false, compact: true, compactWidth: 114) == 5)
        #expect(
            MobileCardLayout.columns(width: 736, accessibilitySize: false, compact: true, compactWidth: 40) == 8)
    }

    @Test(arguments: [false, true])
    func accessibilityGridKeepsOneColumn(compact: Bool) {
        #expect(MobileCardLayout.columns(width: 1334, accessibilitySize: true, compact: compact) == 1)
    }

    @Test(arguments: [(CGFloat(320), 1), (CGFloat(736), 2), (CGFloat(992), 3), (CGFloat(1334), 4)])
    func regularGridKeepsItsMinimumCardWidth(width: CGFloat, expectedColumns: Int) {
        #expect(MobileCardLayout.columns(width: width, accessibilitySize: false) == expectedColumns)
    }

    @Test func dismissingAnOldRowDoesNotCancelAnotherRowsConfirmation() {
        var selectedID: UUID?
        let firstID = UUID()
        let secondID = UUID()
        let selection = Binding(get: { selectedID }, set: { selectedID = $0 })
        let first = selection.isPresenting { $0 == firstID }
        let second = selection.isPresenting { $0 == secondID }

        selectedID = firstID
        #expect(first.wrappedValue && !second.wrappedValue)
        selectedID = secondID
        first.wrappedValue = false
        #expect(!first.wrappedValue && second.wrappedValue)
        #expect(selectedID == secondID)

        second.wrappedValue = false
        #expect(selectedID == nil)
        #expect(!first.wrappedValue && !second.wrappedValue)
    }

    @Test func workspaceConnectionIndicatorHidesDisconnectedWorkspaces() {
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: false, busy: false, reconnecting: false
            ) == nil
        )
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: true, busy: false, reconnecting: false
            ) == .connected
        )
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: false, busy: true, reconnecting: false
            ) == .busy
        )
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: false, busy: false, reconnecting: true
            ) == .busy
        )
        #expect(
            MobileWorkspaceConnectionIndicator.resolve(
                connected: true, busy: true, reconnecting: true
            )?.status == .connected
        )
        #expect(MobileWorkspaceConnectionIndicator.busy.status == .connecting)
    }

    @Test func hostCardsShowAtMostTwoTags() {
        #expect(Array(MobileCardLayout.visibleTags([])).isEmpty)
        #expect(Array(MobileCardLayout.visibleTags(["one"])) == ["one"])
        #expect(Array(MobileCardLayout.visibleTags(["one", "two", "three"])) == ["one", "two"])
    }

    @Test func unnamedForwardingUsesTheHostAndSSHArgument() {
        for (kind, argument) in [(PortForwardingRule.Kind.local, "-L"), (.remote, "-R"), (.dynamic, "-D")] {
            var rule = PortForwardingRule(hostID: UUID(), kind: kind)
            #expect(rule.displayName(hostName: "AWS") == "AWS (\(argument))")
            rule.label = "Database"
            #expect(rule.displayName(hostName: "AWS") == "Database")
            rule.label = "  "
            #expect(rule.displayName(hostName: "AWS") == "AWS (\(argument))")
        }
    }

    @Test func knownHostEditorDistinguishesNewAndSavedEntries() throws {
        let app = try MobileAppModel(inMemory: true)
        let saved = KnownHostEntry(hostname: "saved.example", fingerprint: "SHA256:saved")
        #expect(app.knownHosts.save(saved))

        let add = MobileKnownHostEditor(app: app, entry: KnownHostEntry(hostname: ""))
        let edit = MobileKnownHostEditor(app: app, entry: saved)

        #expect(add.isNew)
        #expect(add.editorTitle == String(localized: AppStrings.KnownHosts.addKnownHost))
        #expect(!edit.isNew)
        #expect(edit.editorTitle == String(localized: AppStrings.KnownHosts.editKnownHost))
    }

    @Test func hostSectionsFoldNestedGroupsKeepEmptyGroupsAndLeaveSearchAvailable() throws {
        let app = try MobileAppModel(inMemory: true)
        let root = HostGroup(name: "Production")
        let child = HostGroup(name: "Edge", parentID: root.id)
        let empty = HostGroup(name: "Empty")
        let rootHost = TermindDomain.Host(name: "Gateway", host: "gateway.example", groupID: root.id)
        let childHost = TermindDomain.Host(name: "Child Node", host: "edge.example", groupID: child.id)
        let ungroupedHost = TermindDomain.Host(name: "Loose", host: "loose.example")

        app.library.upsert(root)
        app.library.upsert(child)
        app.library.upsert(empty)
        app.library.upsert(rootHost)
        app.library.upsert(childHost)
        app.library.upsert(ungroupedHost)

        let expanded = HostLibrarySectionLayout.sections(library: app.library)
        #expect(
            expanded.map(\.id)
                == [.group(root.id), .group(child.id), .group(empty.id), .ungrouped])
        #expect(expanded.map(\.title) == ["Production", "Production / Edge", "Empty", "Ungrouped"])
        #expect(expanded.first(where: { $0.id == .group(empty.id) })?.hosts.isEmpty == true)

        app.library.setExpanded(false, for: root.id)
        let collapsed = HostLibrarySectionLayout.sections(library: app.library)
        #expect(collapsed.map(\.id) == [.group(root.id), .group(empty.id), .ungrouped])
        #expect(app.library.searchHosts("Child Node").map(\.id) == [childHost.id])

        app.library.setUngroupedExpanded(false)
        #expect(
            HostLibrarySectionLayout.sections(library: app.library)
                .first(where: { $0.id == .ungrouped })?.isExpanded == false)

        let stored = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(stored.groups.first(where: { $0.id == root.id })?.isExpanded == true)
    }

    @Test func openingSavedHostsRecordsSSHAndSFTPForTheCardTimestamp() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)

        let ssh = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let sftp = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))

        #expect(Set(app.connectionHistory.entries(for: host.id).map(\.kind)) == [.ssh, .sftp])
        #expect(
            app.connectionHistory.entries(for: host.id).allSatisfy {
                app.devices.name(for: $0.sourceDeviceID)?.isEmpty == false
            })
        #expect(app.connectionHistory.entries(for: host.id).allSatisfy { $0.endedAt == nil })
        #expect(app.lastConnectedAt(for: host.id) != nil)
        let restored = ConnectionHistoryModel(
            repository: SwiftDataConnectionHistoryRepository(context: ModelContext(app.container)))
        #expect(Set(restored.entries(for: host.id).map(\.kind)) == [.ssh, .sftp])

        app.testWorkspaceSession.close(ssh)
        app.testWorkspaceSession.close(sftp)
        #expect(app.connectionHistory.entries(for: host.id).allSatisfy { $0.endedAt != nil })
    }

    @Test func hostAndIdentityColorsRemainDraftsUntilSavedAndRoundTripThroughPersistence() throws {
        let app = try MobileAppModel(inMemory: true)
        var host = TermindDomain.Host(name: "Test", host: "example.invalid", colorTag: .teal)
        var identity = Identity(name: "Deploy", username: "deploy", colorTag: .purple)
        app.library.upsert(host)
        #expect(app.library.upsert(identity))
        host.colorTag = .pink
        identity.colorTag = .orange
        #expect(app.library.host(host.id)?.colorTag == .teal)
        #expect(app.credentials.identities.first?.colorTag == .purple)
        app.library.upsert(host)
        #expect(app.library.upsert(identity))
        let saved = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(saved.hosts.first?.colorTag == .pink)
        #expect(saved.identities.first?.colorTag == .orange)
        host.colorTag = .none
        identity.colorTag = .none
        app.library.upsert(host)
        #expect(app.library.upsert(identity))
        let cleared = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(cleared.hosts.first?.colorTag == TagColor.none)
        #expect(cleared.identities.first?.colorTag == TagColor.none)
    }

    @Test func generatedImportedAndEditedKeysPreserveColorWithoutSavingCancelledDrafts() async throws {
        let app = try MobileAppModel(inMemory: true)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        generator.label = "Colored Key"
        generator.colorTag = .green
        #expect(generator.isDirty)
        try await generator.save()
        let key = try #require(app.credentials.keys.first)
        #expect(key.colorTag == .green)
        let credential = try #require(try app.credentials.keyCredential(for: key))
        guard case .software(let secret) = credential else {
            Issue.record("Expected software key")
            return
        }
        let importer = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        importer.label = "Imported Color"
        importer.privateKey = secret.privateKey
        importer.colorTag = .blue
        try await importer.save()
        #expect(app.credentials.keys.first(where: { $0.label == "Imported Color" })?.colorTag == .blue)

        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
        await editor.loadPrivateKey()
        #expect(editor.colorTag == .green && !editor.isDirty)
        editor.colorTag = .red
        #expect(editor.isDirty)
        #expect(app.credentials.key(key.id)?.colorTag == .green)
        editor.colorTag = .none
        try await editor.save()
        let updated = try #require(app.credentials.key(key.id))
        let reopened = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: updated)
        await reopened.loadPrivateKey()
        #expect(reopened.colorTag == .none && !reopened.isDirty)
        #expect(updated.fingerprint == key.fingerprint)
    }

}
