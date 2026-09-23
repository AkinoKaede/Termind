import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation

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
            result.append(entry(TermindCopy.Common.open, symbol: MenuSymbol.open) { perform(.open) })
            if !file.isDirectory {
                var openWith = SFTPOpenWithMenu(filename: file.name, locale: locale) {
                    perform(.openWith($0))
                }.entry(applications: applications(file.name))
                openWith.isEnabled = connected
                result.append(openWith)
            }
        }
        result.append(
            entry(
                single ? TermindCopy.SFTP.download : TermindCopy.SFTP.downloadItems(targets.count),
                symbol: MenuSymbol.download
            ) {
                perform(.download)
            })
        result.append(.separator)
        result.append(
            entry(single ? TermindCopy.Common.copy : TermindCopy.SFTP.copyItems(targets.count), symbol: MenuSymbol.copy)
            { perform(.copy) })
        result.append(
            NativeMenuEntry(
                title: localized(TermindCopy.SFTP.copyAs), symbol: MenuSymbol.copy,
                children: [
                    entry(single ? TermindCopy.Common.name : TermindCopy.SFTP.names) { perform(.copyNames) },
                    entry(single ? TermindCopy.SFTP.path : TermindCopy.SFTP.paths) { perform(.copyPaths) },
                ]))
        result.append(
            entry(TermindCopy.Common.paste, symbol: MenuSymbol.paste, enabled: connected && canPaste) {
                perform(.paste)
            })
        if single {
            result.append(
                entry(TermindCopy.Common.rename, symbol: MenuSymbol.rename, enabled: allowsRemoteMutations) {
                    perform(.rename)
                })
            if file.kind == .file || file.kind == .directory {
                result.append(
                    entry(
                        TermindCopy.SFTP.editPermissions, symbol: MenuSymbol.editPermissions,
                        enabled: allowsRemoteMutations
                    ) {
                        perform(.editPermissions)
                    })
            }
        }
        result.append(
            entry(
                single ? TermindCopy.Common.delete : TermindCopy.SFTP.deleteItems(targets.count),
                symbol: MenuSymbol.delete,
                imageVisibility: .visible, enabled: allowsRemoteMutations
            ) { perform(.delete) })
        result.append(.separator)
        result.append(
            entry(TermindCopy.SFTP.newFolder, symbol: MenuSymbol.newFolder, enabled: connected) { perform(.newFolder) })
        result.append(
            entry(TermindCopy.SFTP.upload, symbol: MenuSymbol.upload, enabled: connected) { perform(.upload) })
        result.append(
            entry(TermindCopy.Common.refresh, symbol: MenuSymbol.refresh, enabled: connected && !isLoading) {
                perform(.refresh)
            })
        return result
    }

    private func localized(_ title: LocalizedStringResource) -> String {
        AppLocalization.resolve(title, locale: locale)
    }

    private func entry(
        _ title: LocalizedStringResource, symbol: String? = nil,
        imageVisibility: MenuImageVisibility = .automatic, enabled: Bool = true,
        action: @escaping () -> Void
    ) -> NativeMenuEntry {
        NativeMenuEntry(
            title: localized(title), symbol: symbol, imageVisibility: imageVisibility,
            isEnabled: enabled, action: action)
    }
}
