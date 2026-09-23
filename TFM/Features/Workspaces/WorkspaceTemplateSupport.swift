import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

extension Workspace {
    func workspaceTemplateLayout(in hosts: HostLibraryModel) -> WorkspaceTemplateLayout? {
        layout.workspaceTemplateLayout(in: hosts)
    }
}

extension SplitNode {
    func workspaceTemplateLayout(in hosts: HostLibraryModel) -> WorkspaceTemplateLayout? {
        switch self {
        case .leaf(let pane):
            switch pane.content {
            case .sshSession(let session):
                guard hosts.host(session.hostID) != nil else { return nil }
                return .pane(.ssh(hostID: session.hostID))
            case .telnetSession(let session):
                guard hosts.host(session.hostID) != nil else { return nil }
                return .pane(.telnet(hostID: session.hostID))
            case .sftpChannel(let session):
                guard hosts.host(session.hostID) != nil else { return nil }
                return .pane(.sftp(hostID: session.hostID))
            case .empty:
                return .pane(.empty)
            case .serialSession:
                return nil
            }
        case .split(let branch):
            guard let first = branch.first.workspaceTemplateLayout(in: hosts),
                let second = branch.second.workspaceTemplateLayout(in: hosts)
            else { return nil }
            return .split(
                axis: branch.axis == .horizontal ? .horizontal : .vertical,
                fraction: branch.fraction,
                first: first,
                second: second
            )
        }
    }
}

extension WorkspaceTemplateLayout {
    @MainActor
    func makeSplitNode(using hosts: HostLibraryModel) -> (node: SplitNode, missingHosts: Int) {
        switch self {
        case .pane(let descriptor):
            switch descriptor {
            case .empty:
                return (.leaf(Pane(.empty)), 0)
            case .ssh(let hostID):
                guard let host = hosts.host(hostID), host.sshEnabled else { return (.leaf(Pane(.empty)), 1) }
                return (.leaf(.sshSession(host: host)), 0)
            case .telnet(let hostID):
                guard let host = hosts.host(hostID), host.telnetEnabled else { return (.leaf(Pane(.empty)), 1) }
                return (.leaf(.telnetSession(host: host)), 0)
            case .sftp(let hostID):
                guard let host = hosts.host(hostID), host.sshEnabled else { return (.leaf(Pane(.empty)), 1) }
                return (.leaf(.sftpChannel(host: host)), 0)
            }
        case .split(let axis, let fraction, let first, let second):
            let firstResult = first.makeSplitNode(using: hosts)
            let secondResult = second.makeSplitNode(using: hosts)
            return (
                .split(
                    SplitNode.Branch(
                        axis: axis == .horizontal ? .horizontal : .vertical,
                        fraction: fraction,
                        first: firstResult.node,
                        second: secondResult.node
                    )
                ),
                firstResult.missingHosts + secondResult.missingHosts
            )
        }
    }
}

extension WindowModel {
    var canSaveSelectedWorkspaceTemplate: Bool {
        guard let hostStore, let workspace = selectedWorkspace else { return false }
        return workspace.workspaceTemplateLayout(in: hostStore) != nil
    }

    func requestSaveWorkspaceTemplate(_ workspaceID: Workspace.ID? = nil) {
        guard let hosts = hostStore,
            let workspace = workspaceID.flatMap({ id in workspaces.first { $0.id == id } }) ?? selectedWorkspace,
            let layout = workspace.workspaceTemplateLayout(in: hosts)
        else { return }

        select(workspace.id)
        if let templateID = workspace.sourceTemplateID,
            hosts.workspaceTemplate(templateID) != nil
        {
            let name = workspace.title(in: hosts)
            let updated = WorkspaceTemplate(id: templateID, name: name, layout: layout)
            if !hosts.saveWorkspaceTemplate(updated) {
                workspaceTemplateNotice = hosts.storageError
            }
            return
        }

        presentations.workspaceTemplateName = WorkspaceTemplateNamePresentation(
            workspaceID: workspace.id,
            name: workspace.title(in: hosts)
        )
    }

    func commitWorkspaceTemplateName() {
        guard let presentation = presentations.workspaceTemplateName,
            let hosts = hostStore
        else { return }

        guard let workspace = workspaces.first(where: { $0.id == presentation.workspaceID }),
            let layout = workspace.workspaceTemplateLayout(in: hosts)
        else {
            presentation.error = String(localized: AppStrings.Workspace.thisWorkspaceCanNoLongerBeSavedAsATemplate)
            return
        }
        let template = WorkspaceTemplate(name: presentation.name, layout: layout)
        guard hosts.saveWorkspaceTemplate(template) else {
            presentation.error = hosts.storageError
            return
        }
        setTemplateName(template.name, on: workspace)
        workspace.sourceTemplateID = template.id
        presentations.workspaceTemplateName = nil
    }

    @discardableResult
    func openWorkspaceTemplate(_ template: WorkspaceTemplate) -> Workspace? {
        guard let hosts = hostStore else { return nil }
        let result = template.layout.makeSplitNode(using: hosts)
        let workspace = Workspace(pane: result.node.firstPane)
        workspace.layout = result.node
        workspace.focusedPaneID = result.node.firstPane.id
        setTemplateName(template.name, on: workspace)
        workspace.sourceTemplateID = template.id
        open(workspace)
        if result.missingHosts > 0 {
            workspaceTemplateNotice = String(
                localized: AppStrings.Workspace.unavailableHostsWereOpenedAsEmptyPanes(result.missingHosts)
            )
        }
        return workspace
    }

    private func setTemplateName(_ name: String, on workspace: Workspace) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.isSplit {
            workspace.customTitle = name
        } else {
            workspace.focusedPane.customTitle = name
        }
    }
}

struct WorkspaceTemplateNameSheet: View {
    @Environment(WindowModel.self) private var window
    @Bindable var presentation: WorkspaceTemplateNamePresentation
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            Text(title)
                .font(.title2.weight(.semibold))
            TextField(
                AppStrings.Workspace.workspaceName.swiftUIKey, text: $presentation.name.singleLineText,
                axis: .horizontal
            ).singleLinePaste()
                .lineLimit(1)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
            if let error = presentation.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(AppStrings.Common.cancel.swiftUIKey) { window.presentations.workspaceTemplateName = nil }
                    .keyboardShortcut(.cancelAction)
                Button(AppStrings.Common.save.swiftUIKey) { window.commitWorkspaceTemplateName() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(presentation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Metrics.Space.xl)
        .frame(width: 420)
        .onAppear { isNameFocused = true }
    }

    private var title: LocalizedStringResource { AppStrings.Workspace.saveWorkspaceTemplate }
}
