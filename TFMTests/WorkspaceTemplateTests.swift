// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct WorkspaceTemplateTests {
    @Test
    func domainLayoutRoundTripsMixedPanesAndFractions() throws {
        let first = UUID()
        let second = UUID()
        let layout = WorkspaceTemplateLayout.split(
            axis: .horizontal,
            fraction: 0.37,
            first: .pane(.ssh(hostID: first)),
            second: .split(
                axis: .vertical,
                fraction: 0.64,
                first: .pane(.sftp(hostID: second)),
                second: .pane(.empty)
            )
        )
        let template = WorkspaceTemplate(name: "Production", layout: layout)

        #expect(template.isValid)
        #expect(template.layout.paneCount == 3)
        #expect(try JSONDecoder().decode(WorkspaceTemplate.self, from: JSONEncoder().encode(template)) == template)
    }

    @Test
    func liveWorkspaceSavesSavedHostsAndEmptyPanesButRejectsQuickConnect() throws {
        let host = Host(name: "Saved", host: "saved.example")
        let library = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sshSession(host: host)
        workspace.splitFocusedPane(axis: .horizontal, with: Pane(.empty))

        #expect(workspace.workspaceTemplateLayout(in: library) != nil)

        let transient = Host(name: "Once", host: "once.example")
        let quickConnect = Workspace.sshSession(host: transient)
        quickConnect.splitFocusedPane(axis: .horizontal, with: Pane(.empty))
        #expect(quickConnect.workspaceTemplateLayout(in: library) == nil)
    }

    @Test
    func singlePaneWorkspaceCanBeSavedAndKeepsItsTemplateNameWhenOpened() throws {
        let host = Host(name: "Server", host: "server.example")
        let library = HostLibraryModel(hosts: [host])
        let source = Workspace.sshSession(host: host)
        let layout = try #require(source.workspaceTemplateLayout(in: library))
        let template = WorkspaceTemplate(name: "Primary Shell", layout: layout)
        let window = WindowModel()
        window.hostStore = library

        #expect(template.isValid)
        let opened = try #require(window.openWorkspaceTemplate(template))
        #expect(!opened.isSplit)
        #expect(opened.title(in: library) == "Primary Shell")
        #expect(opened.sourceTemplateID == template.id)
    }

    @Test
    func openingTemplateKeepsTreeAndReplacesMissingHostsWithEmptyPanes() throws {
        let available = Host(name: "Available", host: "available.example")
        let missing = UUID()
        let library = HostLibraryModel(hosts: [available])
        let window = WindowModel()
        window.hostStore = library
        let template = WorkspaceTemplate(
            name: "Fleet",
            layout: .split(
                axis: .horizontal,
                fraction: 0.31,
                first: .pane(.ssh(hostID: available.id)),
                second: .split(
                    axis: .vertical,
                    fraction: 0.72,
                    first: .pane(.sftp(hostID: missing)),
                    second: .pane(.empty)
                )
            )
        )

        let workspace = try #require(window.openWorkspaceTemplate(template))

        #expect(workspace.sourceTemplateID == template.id)
        #expect(workspace.customTitle == "Fleet")
        #expect(workspace.panes.map(\.kind) == [.sshSession, .empty, .empty])
        #expect(window.workspaceTemplateNotice != nil)
        guard case .split(let root) = workspace.layout,
            case .split(let nested) = root.second
        else {
            Issue.record("Expected the original nested layout")
            return
        }
        #expect(root.axis == .horizontal)
        #expect(root.fraction == 0.31)
        #expect(nested.axis == .vertical)
        #expect(nested.fraction == 0.72)
    }

    @Test
    func firstSaveBindsAndFollowingSaveUpdatesNameAndLayout() throws {
        let host = Host(name: "Server", host: "server.example")
        let library = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sshSession(host: host)
        workspace.splitFocusedPane(axis: .horizontal, with: Pane(.empty))
        let window = WindowModel(workspaces: [workspace])
        window.hostStore = library

        window.requestSaveWorkspaceTemplate()
        let presentation = try #require(window.presentations.workspaceTemplateName)
        presentation.name = "Operations"
        window.commitWorkspaceTemplateName()

        let templateID = try #require(workspace.sourceTemplateID)
        #expect(library.workspaceTemplate(templateID)?.name == "Operations")

        workspace.customTitle = "Night Operations"
        guard case .split(var branch) = workspace.layout else {
            Issue.record("Expected split layout")
            return
        }
        branch.fraction = 0.42
        workspace.layout = .split(branch)
        window.requestSaveWorkspaceTemplate()

        let updated = try #require(library.workspaceTemplate(templateID))
        #expect(updated.name == "Night Operations")
        guard case .split(_, let fraction, _, _) = updated.layout else {
            Issue.record("Expected split template")
            return
        }
        #expect(fraction == 0.42)
    }

    @Test
    func templateNamesAreTrimmedAndUniqueIgnoringCase() {
        let layout = WorkspaceTemplateLayout.split(
            axis: .horizontal,
            fraction: 0.5,
            first: .pane(.empty),
            second: .pane(.empty)
        )
        let library = HostLibraryModel()

        #expect(library.saveWorkspaceTemplate(WorkspaceTemplate(name: "  Fleet  ", layout: layout)))
        #expect(library.workspaceTemplates.first?.name == "Fleet")
        #expect(!library.saveWorkspaceTemplate(WorkspaceTemplate(name: "fleet", layout: layout)))
    }
}
