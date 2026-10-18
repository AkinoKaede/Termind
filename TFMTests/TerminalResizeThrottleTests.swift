import AppKit
import GhosttyTerminal
import Testing

@testable import Termind

/// These windows are never ordered front or made key; layout and surface lifetime
/// regressions remain covered by the default suite without stealing focus.
@Suite(.serialized) @MainActor
struct TerminalResizeThrottleTests {
    @Test func liveThrottleChangesAreIdempotentAndSurviveRemountWithoutReplacingTheSurface() async throws {
        let fixture = TerminalResizeFixture()
        defer { fixture.close() }
        try await fixture.waitForSurface()
        let owner = fixture.owner
        let state = owner.state
        let surface = try #require(state.surface)
        let controller = state.controller
        let view = try #require(fixture.mount.subviews.first as? TermindTerminalView)
        guard case .inMemory(let backend) = state.configuration.backend else {
            Issue.record("Expected the persistent in-memory backend")
            return
        }
        backend.receive(Data("preserved resize transcript".utf8))
        backend.waitForPendingOutput()
        #expect(!owner.setResizeThrottle(milliseconds: 35))
        for milliseconds in [128.0, 0.0, 35.0, 128.0] {
            #expect(owner.setResizeThrottle(milliseconds: milliseconds))
            #expect(!owner.setResizeThrottle(milliseconds: milliseconds))
            #expect(state.surface === surface)
            #expect(state.controller === controller)
            #expect(state.configuration.resizeThrottleMilliseconds == 35)
            #expect(view.configuration.resizeThrottleMilliseconds == 35)
        }
        let target = TerminalMountView(frame: fixture.mount.frame)
        fixture.window.contentView?.addSubview(target)
        defer { owner.unmount(from: target) }
        owner.mount(in: target, state: state, isVisible: true, requestsFocus: false)
        target.layoutSubtreeIfNeeded()
        owner.unmount(from: fixture.mount)
        #expect(target.subviews.first === view)
        #expect(state.surface === surface)
        #expect(state.controller === controller)
        #expect(view.controller === controller)
        #expect(owner.resizeThrottleMilliseconds == 128)
        #expect(!owner.setResizeThrottle(milliseconds: 128))
        if case .inMemory(let currentBackend) = view.configuration.backend {
            #expect(currentBackend === backend)
        } else {
            Issue.record("Remount replaced the in-memory backend")
        }
        #expect(backend.readViewportText()?.contains("preserved resize transcript") == true)
        #expect(!fixture.window.isVisible)
    }

    @Test(arguments: [0.0, 35.0, 128.0])
    func rapidResizeBurstConvergesWithoutFocusOrFurtherInput(milliseconds: Double) async throws {
        let fixture = TerminalResizeFixture()
        defer { fixture.close() }
        try await fixture.waitForSurface()
        let owner = fixture.owner
        let surface = try #require(owner.state.surface)
        let before = try #require(fixture.resizes.latest)
        owner.setResizeThrottle(milliseconds: milliseconds)
        for width in stride(from: 680, through: 1040, by: 40) {
            fixture.mount.setFrameSize(NSSize(width: CGFloat(width), height: 400))
            fixture.mount.layoutSubtreeIfNeeded()
        }
        let view = try #require(fixture.mount.subviews.first as? TermindTerminalView)
        let finalWidth = UInt32((view.bounds.width * fixture.window.backingScaleFactor).rounded(.down))
        for _ in 0..<200 where fixture.resizes.latest?.widthPixels != finalWidth {
            try await Task.sleep(for: .milliseconds(10))
        }
        let after = try #require(fixture.resizes.latest)
        #expect(after.widthPixels == finalWidth)
        #expect(after.columns > before.columns)
        let count = fixture.resizes.count
        for _ in 0..<10 {
            fixture.mount.setFrameSize(fixture.mount.frame.size)
            fixture.mount.needsLayout = true
            fixture.mount.layoutSubtreeIfNeeded()
        }
        // Let both the 128 ms trailing edge and its final rearm settle.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.resizes.count == count)
        #expect(owner.state.surface === surface)
        #expect(!fixture.window.isVisible)
    }
}

@MainActor
private final class TerminalResizeFixture {
    nonisolated final class Resizes: @unchecked Sendable {
        private let lock = NSLock()
        private var viewports: [InMemoryTerminalViewport] = []

        func receive(_ viewport: InMemoryTerminalViewport) {
            lock.withLock { viewports.append(viewport) }
        }

        var latest: InMemoryTerminalViewport? { lock.withLock { viewports.last } }
        var count: Int { lock.withLock { viewports.count } }
    }

    let resizes = Resizes()
    let owner: PersistentTerminalViewOwner
    let mount = TerminalMountView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let window: NSWindow

    init() {
        let resizes = resizes
        owner = PersistentTerminalViewOwner(write: { _, _ in }, resize: { resizes.receive($0) })
        owner.state.setTerminalConfiguration(
            TerminalConfiguration { builder in
                builder.withWindowPaddingX(0)
                builder.withWindowPaddingY(0)
            })
        window = NSWindow(contentRect: mount.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: mount.frame)
        window.contentView = root
        root.addSubview(mount)
        owner.mount(in: mount, state: owner.state, isVisible: true, requestsFocus: false)
        mount.layoutSubtreeIfNeeded()
    }

    func waitForSurface() async throws {
        for _ in 0..<100 where owner.state.surface == nil || resizes.latest == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(owner.state.surface)
        _ = try #require(resizes.latest)
    }

    func close() {
        owner.unmount(from: mount)
        window.contentView = nil
        window.close()
    }
}
