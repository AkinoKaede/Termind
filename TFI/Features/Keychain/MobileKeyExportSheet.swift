import SwiftUI
import TermindApplication

struct MobileKeyExportSheet: View {
    let library: HostLibraryModel
    let credentials: CredentialLibraryModel
    @State var model: MobileKeyExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MobileMultiHostPicker(library: library, credentials: credentials, exporting: model, close: { dismiss() })
    }
}
