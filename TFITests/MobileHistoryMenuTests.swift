import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileHistoryMenuTests {
    @Test func historyImagesRemainVisibleIncludingShowHistoryAndNestedProtocols() {
        guard #available(iOS 27.0, *) else { return }
        let show = UIKeyCommand(
            title: "显示历史记录", image: UIImage(systemName: "clock.arrow.circlepath"),
            action: Selector(("showHistory:")), input: "y", modifierFlags: .command)
        let ssh = UIAction(title: "Server", image: UIImage(systemName: "terminal")) { _ in }
        let sftp = UIAction(title: "Server", image: UIImage(systemName: "folder")) { _ in }
        let reopen = UIAction(title: "Reopen Window", image: UIImage(systemName: "macwindow")) { _ in }
        let closedWindow = UIMenu(title: "Server", image: UIImage(systemName: "terminal"), children: [reopen, ssh])
        let recentlyClosed = UIMenu(title: "Recently Closed", children: [closedWindow])
        let day = UIMenu(title: "Earlier Today", image: UIImage(systemName: "clock"), children: [sftp])
        let history = UIMenu(title: "历史记录", children: [show, recentlyClosed, day])
        #expect(MobileHistoryMenuImages.containsHistoryShortcut(history))
        #expect(!MobileHistoryMenuImages.containsHistoryShortcut(day))
        MobileHistoryMenuImages.revealImages(in: history)
        for element in [show, closedWindow, reopen, ssh, day, sftp] {
            #expect(element.preferredImageVisibility == .visible)
        }
    }
}
