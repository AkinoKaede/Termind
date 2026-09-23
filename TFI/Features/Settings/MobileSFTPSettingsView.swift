import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileConnectionSettingsView: View {
    let ssh: SSHSettingsModel
    let sftp: SFTPSettingsModel

    var body: some View {
        Form {
            Section(TermindCopy.Vault.ssh.swiftUIKey) { SSHSettingsFields(model: ssh) }
            Section(TermindCopy.SFTP.sftp.swiftUIKey) { SFTPSettingsFields(model: sftp) }
        }
        .navigationTitle(TermindCopy.Settings.connections.swiftUIKey)
    }
}
