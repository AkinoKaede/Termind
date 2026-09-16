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
            title: mode == .rename ? String(localized: "Rename") : String(localized: "Edit Permissions"),
            isDirty: name != file.name || permissions.text != SFTPPermissionDraft.octalString(for: file.permissions),
            canSave: workspace.connected
                && (mode == .rename ? !name.isEmpty && name != file.name : permissions.canSave),
            compact: mode == .rename,
            save: {
                if mode == .rename {
                    try await workspace.sftpSession.rename(file, to: name)
                } else {
                    try await workspace.sftpSession.setPermissions(file, mode: permissions.mode)
                }
            },
            content: {
                Section { Text(file.path).font(.caption.monospaced()).textSelection(.enabled) }
                if mode == .rename {
                    TextField("Name", text: $name.singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .multilineTextAlignment(.leading)
                } else {
                    Section("Permissions") {
                        TextField(
                            "Octal permissions",
                            text: Binding(
                                get: { permissions.text },
                                set: { _ = permissions.accept($0) }
                            ).singleLineText, axis: .horizontal
                        ).singleLinePaste().lineLimit(1)
                            .font(.body.monospaced())
                            .keyboardType(.numberPad)
                    }
                    Section("File Access") { UnixPermissionGrid(draft: $permissions) }
                    Section("Ownership") {
                        LabeledContent("UID", value: file.ownerUID.formatted())
                        LabeledContent("GID", value: file.ownerGID.formatted())
                    }
                }
            })
    }
}
