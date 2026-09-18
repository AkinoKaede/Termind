import Foundation
import TermindApplication
import TermindDomain

/// A menu snapshot, built only in response to a context click, never during
/// SwiftUI row rendering. Actions retain the caller's corresponding targets.
@MainActor
struct SFTPFileContextMenu {
    enum Action: Equatable {
        case open
        case openWith(URL)
        case download, copy, copyNames, copyPaths, paste
        case rename, editPermissions, delete, newFolder, upload, refresh
    }

    let file: RemoteFile
    let targets: [RemoteFile]
    let connected: Bool
    let allowsRemoteMutations: Bool
    let canPaste: Bool
    let isLoading: Bool
    let locale: Locale

    func entries(
        applications: @MainActor (String) -> [SFTPFileApplication] = SFTPApplicationOpener.applications(for:),
        perform: @escaping (Action) -> Void
    ) -> [NativeMenuEntry] {
        let single = targets.count == 1
        var result: [NativeMenuEntry] = []
        if single {
            result.append(entry("Open", symbol: MenuSymbol.open) { perform(.open) })
            if !file.isDirectory {
                var openWith = SFTPOpenWithMenu(filename: file.name, locale: locale) {
                    perform(.openWith($0))
                }.entry(applications: applications(file.name))
                openWith.isEnabled = connected
                result.append(openWith)
            }
        }
        result.append(
            entry(single ? "Download" : "Download \(targets.count) Items", symbol: MenuSymbol.download) {
                perform(.download)
            })
        result.append(.separator)
        result.append(
            entry(single ? "Copy" : "Copy \(targets.count) Items", symbol: MenuSymbol.copy) { perform(.copy) })
        result.append(
            NativeMenuEntry(
                title: localized("Copy As"), symbol: MenuSymbol.copy,
                children: [
                    entry(single ? "Name" : "Names") { perform(.copyNames) },
                    entry(single ? "Path" : "Paths") { perform(.copyPaths) },
                ]))
        result.append(entry("Paste", symbol: MenuSymbol.paste, enabled: connected && canPaste) { perform(.paste) })
        if single {
            result.append(
                entry("Rename", symbol: MenuSymbol.rename, enabled: allowsRemoteMutations) { perform(.rename) })
            if file.kind == .file || file.kind == .directory {
                result.append(
                    entry("Edit Permissions", symbol: MenuSymbol.editPermissions, enabled: allowsRemoteMutations) {
                        perform(.editPermissions)
                    })
            }
        }
        result.append(
            entry(
                single ? "Delete" : "Delete \(targets.count) Items", symbol: MenuSymbol.delete,
                enabled: allowsRemoteMutations
            ) { perform(.delete) })
        result.append(.separator)
        result.append(entry("New Folder", symbol: MenuSymbol.newFolder, enabled: connected) { perform(.newFolder) })
        result.append(entry("Upload", symbol: MenuSymbol.upload, enabled: connected) { perform(.upload) })
        result.append(
            entry("Refresh", symbol: MenuSymbol.refresh, enabled: connected && !isLoading) { perform(.refresh) })
        return result
    }

    private func localized(_ title: String.LocalizationValue) -> String {
        AppLocalization.string(title, locale: locale)
    }

    private func entry(
        _ title: String.LocalizationValue, symbol: String? = nil, enabled: Bool = true,
        action: @escaping () -> Void
    ) -> NativeMenuEntry {
        NativeMenuEntry(title: localized(title), symbol: symbol, isEnabled: enabled, action: action)
    }
}
