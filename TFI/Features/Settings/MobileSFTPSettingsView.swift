import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileConnectionSettingsView: View {
    let ssh: SSHSettingsModel
    let sftp: SFTPSettingsModel

    var body: some View {
        Form {
            Section("SSH") { SSHSettingsFields(model: ssh) }
            Section("SFTP") { SFTPSettingsFields(model: sftp) }
        }
        .navigationTitle("Connections")
    }
}
