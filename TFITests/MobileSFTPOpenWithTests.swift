// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileSFTPOpenWithTests {
    @Test func completedDownloadUsesTheManagedCopyAndCurrentWindowAnchor() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        let anchor = UIView(frame: window.bounds)
        window.addSubview(anchor)
        var presented: URL?
        let presenter = MobileSFTPOpenWithPresenter { controller, view in
            #expect(view === anchor)
            #expect(view.window === window)
            presented = controller.url
            return true
        }
        presenter.sourceView = anchor
        presenter.isEnabled = true
        let request = try #require(presenter.begin())
        #expect(presenter.controller == nil)
        let managedCopy = URL(filePath: "/tmp/TermindEdits/managed/document.pdf")
        presenter.downloaded(managedCopy, request: request)
        #expect(presented == managedCopy)
        let controller = try #require(presenter.controller)
        presenter.documentInteractionControllerDidDismissOpenInMenu(controller)
        #expect(presenter.controller == nil)
    }

    @Test func backgroundAndWorkspaceChangesInvalidateLateDownloads() throws {
        let window = UIWindow()
        let anchor = UIView()
        window.addSubview(anchor)
        let presenter = MobileSFTPOpenWithPresenter { _, _ in
            Issue.record("A retired request must not present")
            return true
        }
        presenter.sourceView = anchor
        presenter.isEnabled = true
        let request = try #require(presenter.begin())
        presenter.isEnabled = false
        presenter.isEnabled = true
        presenter.downloaded(URL(filePath: "/tmp/old.pdf"), request: request)
        #expect(presenter.controller == nil)
        let next = try #require(presenter.begin())
        presenter.invalidate()
        presenter.downloaded(URL(filePath: "/tmp/next.pdf"), request: next)
        #expect(presenter.controller == nil)
        let superseded = try #require(presenter.begin())
        _ = presenter.begin()
        presenter.downloaded(URL(filePath: "/tmp/superseded.pdf"), request: superseded)
        #expect(presenter.controller == nil)
    }

    @Test func noCompatibleApplicationReportsAnErrorAndReleasesController() throws {
        let window = UIWindow()
        let anchor = UIView()
        window.addSubview(anchor)
        let presenter = MobileSFTPOpenWithPresenter { _, _ in false }
        presenter.sourceView = anchor
        presenter.isEnabled = true
        var error: String?
        presenter.failed = { error = $0 }
        presenter.downloaded(URL(filePath: "/tmp/unknown"), request: try #require(presenter.begin()))
        #expect(error != nil)
        #expect(presenter.controller == nil)
    }

    @Test func handoffRetainsControllerAcrossSceneDeactivationUntilSendingFinishes() throws {
        let window = UIWindow()
        let anchor = UIView()
        window.addSubview(anchor)
        let presenter = MobileSFTPOpenWithPresenter { _, _ in true }
        presenter.sourceView = anchor
        presenter.isEnabled = true
        var finished = 0
        presenter.finished = { finished += 1 }
        presenter.downloaded(URL(filePath: "/tmp/file.pdf"), request: try #require(presenter.begin()))
        let controller = try #require(presenter.controller)
        presenter.documentInteractionController(controller, willBeginSendingToApplication: "test.editor")
        presenter.isEnabled = false
        presenter.documentInteractionControllerDidDismissOpenInMenu(controller)
        #expect(presenter.controller === controller)
        #expect(finished == 0)
        presenter.documentInteractionController(controller, didEndSendingToApplication: "test.editor")
        #expect(presenter.controller == nil)
        #expect(finished == 1)
    }

    @Test func closingWorkspaceDuringHandoffKeepsTheDelegateUntilCompletion() throws {
        let window = UIWindow()
        let anchor = UIView()
        window.addSubview(anchor)
        var presenter: MobileSFTPOpenWithPresenter? = MobileSFTPOpenWithPresenter { _, _ in true }
        presenter?.sourceView = anchor
        presenter?.isEnabled = true
        presenter?.downloaded(URL(filePath: "/tmp/file.pdf"), request: try #require(presenter?.begin()))
        let controller = try #require(presenter?.controller)
        presenter?.documentInteractionController(controller, willBeginSendingToApplication: "test.editor")
        weak var retained = presenter
        defer { retained = nil }
        presenter = nil
        #expect(retained != nil)
        retained?.documentInteractionController(controller, didEndSendingToApplication: "test.editor")
        #expect(retained == nil)
    }
}
