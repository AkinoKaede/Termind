import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileHistoryMenuTests {
    @Test func onlyShowHistoryAndConnectionRecordsForceImagesVisible() throws {
        guard #available(iOS 27.0, *) else { return }
        let show = UIKeyCommand(
            title: "显示历史记录", image: UIImage(systemName: "clock.arrow.circlepath"),
            action: Selector(("showHistory:")), input: "y", modifierFlags: .command)
        let ssh = UIAction(title: "Server", image: MobileHistoryMenuConfiguration.recordImage(systemName: "terminal")) {
            _ in
        }
        let sftp = UIAction(title: "Server", image: MobileHistoryMenuConfiguration.recordImage(systemName: "folder")) {
            _ in
        }
        let reopen = UIAction(title: "Reopen Window", image: UIImage(systemName: "macwindow")) { _ in }
        let closedWindow = UIMenu(
            title: "Server", image: MobileHistoryMenuConfiguration.recordImage(systemName: "terminal"),
            children: [reopen, ssh])
        let recentlyClosed = UIMenu(
            title: "Recently Closed", image: UIImage(systemName: "clock.arrow.circlepath"), children: [closedWindow])
        let day = UIMenu(title: "Earlier Today", image: UIImage(systemName: "clock"), children: [sftp])
        let date = UIMenu(title: "2026/10/5", image: UIImage(systemName: "calendar"), children: [])
        let reopenLast = UIKeyCommand(
            title: "Reopen Last Closed Workspace", image: UIImage(systemName: "arrow.uturn.backward"),
            action: Selector(("reopen:")), input: "t", modifierFlags: [.command, .shift])
        let clear = UIAction(title: "Clear History", image: UIImage(systemName: "clock.badge.xmark")) { _ in }
        let history = UIMenu(title: "历史记录", children: [show, recentlyClosed, reopenLast, day, date, clear])
        #expect(MobileHistoryMenuConfiguration.containsHistoryShortcut(history))
        #expect(!MobileHistoryMenuConfiguration.containsHistoryShortcut(day))
        let configured = MobileHistoryMenuConfiguration.configured(history)
        let elements = descendants(of: configured)
        for original in [show, closedWindow, ssh, sftp] as [UIMenuElement] {
            let element = try #require(elements.first { $0.title == original.title && $0.image == original.image })
            #expect(element.preferredImageVisibility == .visible)
        }
        for original in [recentlyClosed, reopen, reopenLast, day, date, clear] as [UIMenuElement] {
            let element = try #require(elements.first { $0.title == original.title })
            #expect(element.preferredImageVisibility == .automatic)
        }
    }

    @Test func longDateMenusKeepAllRowsAndUseSingleLineTitles() throws {
        guard #available(iOS 27.0, *) else { return }
        let rows = (0..<100).map { index in
            UIAction(
                title: "A long host name that wraps in narrow submenus \(index)",
                image: MobileHistoryMenuConfiguration.recordImage(systemName: "terminal")
            ) { _ in }
        }
        let day = UIMenu(title: "2026/10/5", children: rows)
        let inline = UIMenu(options: .displayInline, children: [day])
        let history = UIMenu(title: "History", children: [inline])
        let configured = MobileHistoryMenuConfiguration.configured(history)
        let elements = descendants(of: configured)
        let actualRows = elements.compactMap { $0 as? UIAction }
        #expect(actualRows.map(\.identifier) == rows.map(\.identifier))
        for menu in [configured] + elements.compactMap({ $0 as? UIMenu }) {
            #expect(menu.displayPreferences?.maximumNumberOfTitleLines == 1)
        }
    }

    private func descendants(of menu: UIMenu) -> [UIMenuElement] {
        menu.children.flatMap { element -> [UIMenuElement] in
            [element] + ((element as? UIMenu).map(descendants) ?? [])
        }
    }
}
