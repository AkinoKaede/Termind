import AppKit
import SwiftUI
import Testing

@testable import Termind

@MainActor
struct SheetApplicationTerminationTests {
    @Test(arguments: [false, true])
    func mountingAndRepeatedUpdatesAllowQuitAndRemovalRestoresTheOriginalValue(original: Bool) {
        let window = makeWindow(preventsTermination: original)
        defer { window.close() }
        let bridge = SheetApplicationTerminationView(frame: .zero)

        window.contentView?.addSubview(bridge)
        #expect(!window.preventsApplicationTerminationWhenModal)
        bridge.apply()
        bridge.apply()
        #expect(!window.preventsApplicationTerminationWhenModal)

        bridge.removeFromSuperview()
        #expect(window.preventsApplicationTerminationWhenModal == original)
        bridge.restore()
        #expect(window.preventsApplicationTerminationWhenModal == original)
    }

    @Test
    func movingBetweenWindowsRestoresEachWindowIndependently() {
        let first = makeWindow(preventsTermination: true)
        let second = makeWindow(preventsTermination: false)
        let untouched = makeWindow(preventsTermination: true)
        defer {
            first.close()
            second.close()
            untouched.close()
        }
        let bridge = SheetApplicationTerminationView(frame: .zero)
        first.contentView?.addSubview(bridge)
        #expect(!first.preventsApplicationTerminationWhenModal)

        second.contentView?.addSubview(bridge)
        #expect(first.preventsApplicationTerminationWhenModal)
        #expect(!second.preventsApplicationTerminationWhenModal)
        #expect(untouched.preventsApplicationTerminationWhenModal)

        bridge.restore()
        #expect(!second.preventsApplicationTerminationWhenModal)
        bridge.removeFromSuperview()
        first.contentView?.addSubview(bridge)
        #expect(!first.preventsApplicationTerminationWhenModal)
        bridge.removeFromSuperview()
        #expect(first.preventsApplicationTerminationWhenModal)
    }

    @Test
    func swiftUIContentAppliesThePolicyAndReplacingItRestoresTheWindow() async throws {
        let window = makeWindow(preventsTermination: true)
        defer { window.close() }
        let host = NSHostingView(
            rootView: Color.clear.frame(width: 200, height: 100).allowsApplicationTerminationWhenModal())
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(!window.preventsApplicationTerminationWhenModal)

        window.contentView = NSView()
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.preventsApplicationTerminationWhenModal)
    }

    private func makeWindow(preventsTermination: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.preventsApplicationTerminationWhenModal = preventsTermination
        return window
    }
}
