import SwiftUI
import TermindDomain
import TermindPresentation

struct MobileRemoteFileEditor: View {
    enum Mode { case rename, permissions }
    let workspace: MobileWorkspace
    let file: RemoteFile
    let mode: Mode
    @State private var name: String
    @State private var permissions: SFTPPermissionDraft

    init(workspace: MobileWorkspace, file: RemoteFile, mode: Mode) {
        self.workspace = workspace
        self.file = file
        self.mode = mode
        _name = State(initialValue: file.name)
        _permissions = State(initialValue: SFTPPermissionDraft(permissions: file.permissions))
    }

    var body: some View {
        MobileEditorSheet(
            title: mode == .rename
                ? String(localized: TermindCopy.Common.rename) : String(localized: TermindCopy.SFTP.editPermissions),
            isDirty: name != file.name || permissions.text != SFTPPermissionDraft.octalString(for: file.permissions),
            canSave: workspace.connected
                && (mode == .rename ? !name.isEmpty && name != file.name : permissions.canSave),
            compact: mode == .rename,
            save: {
                if mode == .rename {
                    try await workspace.sftpChannel.rename(file, to: name)
                } else {
                    try await workspace.sftpChannel.setPermissions(file, mode: permissions.mode)
                }
            },
            content: {
                Section { Text(file.path).font(.caption.monospaced()).textSelection(.enabled) }
                if mode == .rename {
                    TextField(TermindCopy.Common.name.swiftUIKey, text: $name.singleLineText, axis: .horizontal)
                        .singleLinePaste().lineLimit(1)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .multilineTextAlignment(.leading)
                } else {
                    Section(TermindCopy.SFTP.permissions.swiftUIKey) {
                        TextField(
                            TermindCopy.SFTP.octalPermissions.swiftUIKey,
                            text: Binding(
                                get: { permissions.text },
                                set: { _ = permissions.accept($0) }
                            ).singleLineText, axis: .horizontal
                        ).singleLinePaste().lineLimit(1)
                            .font(.body.monospaced())
                            .keyboardType(.numberPad)
                    }
                    Section(TermindCopy.SFTP.fileAccess.swiftUIKey) { UnixPermissionGrid(draft: $permissions) }
                    Section(TermindCopy.SFTP.ownership.swiftUIKey) {
                        LabeledContent(TermindCopy.SFTP.uid.swiftUIKey, value: file.ownerUID.formatted())
                        LabeledContent(TermindCopy.SFTP.gid.swiftUIKey, value: file.ownerGID.formatted())
                    }
                }
            })
    }
}
