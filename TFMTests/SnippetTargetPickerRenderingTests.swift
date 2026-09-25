import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct SnippetTargetPickerRenderingTests {
    @Test
    func targetPickerFitsTheVaultColumnAndKeepsCancelAndDoneTransactional() async throws {
        let first = Host(name: "Alpha", host: "alpha.invalid", sortIndex: 0)
        let second = Host(name: "Bravo", host: "bravo.invalid", sortIndex: 1)
        let app = AppModel(hosts: HostLibraryModel(hosts: [first, second]))
        let capture = Capture()
        let fixture = PickerFixture(app: app, capture: capture)
        defer {
            fixture.close()
            app.shutdownForTermination()
        }

        fixture.mount(selected: [first.id])
        await fixture.settle()
        let search = try #require(fixture.visibleTextFields.first { $0.isEditable })
        fixture.assertInsideColumn(search)

        search.stringValue = "none"
        search.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: search)
        )
        await fixture.settle()
        #expect(fixture.controller.view.bounds.width == Metrics.VaultDetail.width)
        try fixture.recordScreenshot(name: "snippet-target-picker-no-results")

        search.stringValue = "Bravo"
        search.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: search)
        )
        await fixture.settle()
        try fixture.focusSearch()
        try fixture.sendKey(" ", code: 49)
        try fixture.performKeyEquivalent("\u{1B}", code: 53)
        #expect(capture.backCount == 1)
        #expect(capture.saved == nil)
        let cancelBackCount = capture.backCount

        fixture.mount(selected: [first.id])
        await fixture.settle()
        let reopenedSearch = try #require(fixture.visibleTextFields.first { $0.isEditable })
        reopenedSearch.stringValue = "Bravo"
        reopenedSearch.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: reopenedSearch)
        )
        await fixture.settle()
        try fixture.focusSearch()
        try fixture.sendKey(" ", code: 49)
        try fixture.performKeyEquivalent("\r", code: 36)
        #expect(capture.backCount == cancelBackCount + 1)
        #expect(capture.saved == [first.id, second.id])
    }

    private final class Capture {
        var backCount = 0
        var saved: Set<Host.ID>?
    }

    private final class PickerFixture {
        let app: AppModel
        let capture: Capture
        let window = NSWindow(
            contentRect: CGRect(
                x: 0, y: 0, width: Metrics.VaultDetail.width, height: 700
            ),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        private(set) var controller = NSHostingController(rootView: AnyView(Color.clear))

        init(app: AppModel, capture: Capture) {
            self.app = app
            self.capture = capture
            window.isReleasedWhenClosed = false
        }

        func mount(selected: Set<Host.ID>) {
            controller = NSHostingController(
                rootView: AnyView(
                    SnippetTargetPickerView(
                        selected: selected,
                        back: { self.capture.backCount += 1 },
                        save: { self.capture.saved = $0 }
                    )
                    .environment(app)
                    .environment(\.locale, Locale(identifier: "en"))
                )
            )
            controller.sizingOptions = []
            window.contentViewController = controller
            window.setContentSize(
                CGSize(width: Metrics.VaultDetail.width, height: 700)
            )
            controller.view.frame = CGRect(
                x: 0, y: 0, width: Metrics.VaultDetail.width, height: 700
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        var visibleTextFields: [NSTextField] {
            descendants.compactMap { $0 as? NSTextField }.filter {
                !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }
        }

        func assertInsideColumn(_ view: NSView) {
            let frame = view.convert(view.bounds, to: controller.view)
            #expect(frame.minX >= -1)
            #expect(frame.maxX <= Metrics.VaultDetail.width + 1)
        }

        func sendKey(_ characters: String, code: UInt16) throws {
            NSApp.sendEvent(try keyEvent(characters, code: code))
        }

        func focusSearch() throws {
            let search = try #require(visibleTextFields.first { $0.isEditable })
            #expect(window.makeFirstResponder(search))
        }

        func performKeyEquivalent(_ characters: String, code: UInt16) throws {
            #expect(window.performKeyEquivalent(with: try keyEvent(characters, code: code)))
        }

        private func keyEvent(_ characters: String, code: UInt16) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code
                )
            )
        }

        func recordScreenshot(name: String) throws {
            let view = controller.view
            let bitmap = try #require(
                view.bitmapImageRepForCachingDisplay(in: view.bounds)
            )
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(data, named: "\(name).png")
        }

        func settle() async {
            controller.view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))
            controller.view.layoutSubtreeIfNeeded()
        }

        func close() {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }

        private var descendants: [NSView] {
            func walk(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(walk)
            }
            return walk(controller.view)
        }

    }
}
