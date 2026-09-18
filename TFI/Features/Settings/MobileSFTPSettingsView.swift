import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileSFTPSettingsView: View {
    let model: SFTPSettingsModel

    var body: some View {
        Form {
            Section("SFTP") { SFTPSettingsFields(model: model) }
        }
        .navigationTitle("SFTP")
    }
}
