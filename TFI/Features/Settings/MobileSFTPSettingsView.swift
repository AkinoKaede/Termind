import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileConnectionSettingsView: View {
    let ssh: SSHSettingsModel
    let sftp: SFTPSettingsModel
    var sftpAccess = MultiConnectionSettingsAccess(isAllowed: true, requestAccess: {})

    var body: some View {
        Form {
            Section(AppStrings.Vault.ssh.swiftUIKey) { SSHSettingsFields(model: ssh) }
            Section(AppStrings.SFTP.sftp.swiftUIKey) { SFTPSettingsFields(model: sftp, access: sftpAccess) }
        }
        .navigationTitle(AppStrings.Settings.connections.swiftUIKey)
    }
}
