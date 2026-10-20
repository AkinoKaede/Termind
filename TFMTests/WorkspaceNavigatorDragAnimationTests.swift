// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing

@testable import Termind

@Suite @MainActor
struct WorkspaceNavigatorDragAnimationTests {
    @Test
    func animationAdapterForwardsRowsAndPreservesDataSourceReplacement() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        let outline = NSOutlineView(frame: root.bounds)
        let original = Rows()
        outline.dataSource = original
        let scrollView = NSScrollView(frame: root.bounds)
        scrollView.documentView = outline
        root.addSubview(scrollView)
        let marker = WorkspaceNavigatorDragAnimationView(frame: root.bounds)
        root.addSubview(marker)
        marker.refreshBinding()

        let proxy = try #require(outline.dataSource as? WorkspaceNavigatorDragAnimationDataSource)
        #expect(proxy.forwardedDataSource === original)
        outline.reloadData()
        #expect(outline.numberOfRows == 1)
        let item = try #require(outline.item(atRow: 0))
        let writer = try #require(outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: item))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([writer]))
        #expect(pasteboard.string(forType: .string) == "workspace")

        let replacement = Rows()
        outline.dataSource = replacement
        marker.unbind()
        #expect(outline.dataSource === replacement)

        marker.refreshBinding()
        #expect(outline.dataSource is WorkspaceNavigatorDragAnimationDataSource)
        marker.removeFromSuperview()
        #expect(outline.dataSource === replacement)
    }

    private final class Rows: NSObject, NSOutlineViewDataSource {
        let item = NSString(string: "workspace")

        func outlineView(_: NSOutlineView, numberOfChildrenOfItem _: Any?) -> Int { 1 }
        func outlineView(_: NSOutlineView, child _: Int, ofItem _: Any?) -> Any { item }
        func outlineView(_: NSOutlineView, isItemExpandable _: Any) -> Bool { false }
        func outlineView(_: NSOutlineView, pasteboardWriterForItem _: Any) -> (any NSPasteboardWriting)? { item }
    }
}
