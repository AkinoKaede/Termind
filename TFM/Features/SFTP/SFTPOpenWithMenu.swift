import SwiftUI

struct SFTPOpenWithMenu: View {
    let filename: String
    let open: (URL) -> Void

    var body: some View {
        Menu("Open With") {
            let applications = SFTPApplicationOpener.applications(for: filename)
            if let defaultApplication = applications.first(where: \.isDefault) {
                applicationButton(defaultApplication)
                Divider()
            }
            let otherApplications = applications.filter { !$0.isDefault }
            ForEach(otherApplications) { application in
                applicationButton(application)
            }
            if !otherApplications.isEmpty { Divider() }
            Button("App Store…") {
                SFTPApplicationOpener.openAppStore(for: filename)
            }
            .disabled(SFTPApplicationOpener.appStoreSearchURL(for: filename) == nil)
            Button("Other…") {
                Task {
                    if let application = await SFTPApplicationOpener.chooseApplication() { open(application) }
                }
            }
        }
    }

    private func applicationButton(_ application: SFTPFileApplication) -> some View {
        Button {
            open(application.url)
        } label: {
            if let icon = application.icon {
                Label {
                    Text(verbatim: title(for: application))
                } icon: {
                    Image(nsImage: icon)
                }
            } else {
                Text(verbatim: title(for: application))
            }
        }
    }

    private func title(for application: SFTPFileApplication) -> String {
        guard application.isDefault else { return application.name }
        return String.localizedStringWithFormat(String(localized: "%@ (default)"), application.name)
    }
}
