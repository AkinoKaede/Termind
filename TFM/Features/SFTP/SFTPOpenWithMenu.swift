import SwiftUI

struct SFTPOpenWithMenu: View {
    let filename: String
    let open: (URL) -> Void
    @State private var applications: [SFTPFileApplication] = []

    var body: some View {
        Menu("Open With") {
            ForEach(applications) { application in
                Button {
                    open(application.url)
                } label: {
                    HStack {
                        if let icon = application.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        if application.isDefault {
                            Text("\(application.name) (default)")
                        } else {
                            Text(verbatim: application.name)
                        }
                    }
                }
            }
            if !applications.isEmpty { Divider() }
            Button("Other…") {
                Task {
                    if let application = await SFTPApplicationOpener.chooseApplication() { open(application) }
                }
            }
        }
        // Context menu content appears only when requested, not while rendering file rows.
        .onAppear { applications = SFTPApplicationOpener.applications(for: filename) }
    }
}
