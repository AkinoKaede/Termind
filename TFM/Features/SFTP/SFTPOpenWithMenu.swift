// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindApplication
import TermindPresentation

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
                title: AppLocalization.resolve(AppStrings.SFTP.appStoreProgress, locale: locale),
                isEnabled: SFTPApplicationOpener.appStoreSearchURL(for: filename) != nil,
                action: { SFTPApplicationOpener.openAppStore(for: filename) }
            ))
        children.append(
            NativeMenuEntry(title: AppLocalization.resolve(AppStrings.SFTP.otherProgress, locale: locale)) {
                Task {
                    if let application = await SFTPApplicationOpener.chooseApplication() { open(application) }
                }
            })
        return NativeMenuEntry(
            title: AppLocalization.resolve(AppStrings.SFTP.openWith, locale: locale), children: children)
    }

    private func applicationEntry(_ application: SFTPFileApplication) -> NativeMenuEntry {
        let title =
            application.isDefault
            ? String(
                format: AppLocalization.resolve("%@ (default)", locale: locale),
                locale: locale, application.name)
            : application.name
        return NativeMenuEntry(title: title, image: application.icon) { open(application.url) }
    }
}
