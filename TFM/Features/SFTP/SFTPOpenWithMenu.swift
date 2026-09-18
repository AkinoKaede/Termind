import AppKit
import TermindApplication

@MainActor
struct SFTPOpenWithMenu {
    let filename: String
    let locale: Locale
    let open: (URL) -> Void

    func entry(applications: [SFTPFileApplication]) -> NativeMenuEntry {
        var children: [NativeMenuEntry] = []
        if let defaultApplication = applications.first(where: \.isDefault) {
            children.append(applicationEntry(defaultApplication))
            children.append(.separator)
        }
        let otherApplications = applications.filter { !$0.isDefault }
        children += otherApplications.map(applicationEntry)
        if !otherApplications.isEmpty { children.append(.separator) }
        children.append(
            NativeMenuEntry(
                title: AppLocalization.string("App Store…", locale: locale),
                isEnabled: SFTPApplicationOpener.appStoreSearchURL(for: filename) != nil,
                action: { SFTPApplicationOpener.openAppStore(for: filename) }
            ))
        children.append(
            NativeMenuEntry(title: AppLocalization.string("Other…", locale: locale)) {
                Task {
                    if let application = await SFTPApplicationOpener.chooseApplication() { open(application) }
                }
            })
        return NativeMenuEntry(title: AppLocalization.string("Open With", locale: locale), children: children)
    }

    private func applicationEntry(_ application: SFTPFileApplication) -> NativeMenuEntry {
        let title =
            application.isDefault
            ? String(
                format: AppLocalization.string("%@ (default)", locale: locale),
                locale: locale, application.name)
            : application.name
        return NativeMenuEntry(title: title, image: application.icon) { open(application.url) }
    }
}
