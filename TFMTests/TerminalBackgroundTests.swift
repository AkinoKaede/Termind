import AppKit
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct TerminalBackgroundTests {
    @Test func mountedBackgroundFollowsThemeCustomConfigurationAndAppearance() async throws {
        let state = TerminalViewState(configSource: .none)
        state.applyPreferences(.init())
        let host = NSHostingView(rootView: TerminalBackground(state: state).frame(width: 80, height: 80))
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        try await expectPixel(in: host, x: 40, y: 40, color: state.backgroundColor)

        state.applyPreferences(
            .init(
                darkCustomEnabled: true, lightCustomEnabled: true,
                darkCustomConfiguration: "background = 445566", lightCustomConfiguration: "background = 112233"))
        let light = TerminalColor(red: 0x11, green: 0x22, blue: 0x33)
        #expect(state.backgroundColor == light)
        try await expectPixel(in: host, x: 40, y: 40, color: light)
        state.adopt(terminalColorScheme: .dark)
        let dark = TerminalColor(red: 0x44, green: 0x55, blue: 0x66)
        #expect(state.backgroundColor == dark)
        try await expectPixel(in: host, x: 40, y: 40, color: dark)

        state.terminalDidChangeColor(.init(kind: .foreground, color: light))
        try await expectPixel(in: host, x: 40, y: 40, color: dark)
    }

    @Test func oscBackgroundAndResetUpdateOnlyTheirOwnSplitHeaderWithoutReplacingSurfaces() async throws {
        let firstHost = TermindDomain.Host(name: "First", host: "first.example.invalid")
        let secondHost = TermindDomain.Host(name: "Second", host: "second.example.invalid")
        let workspace = Workspace.sshSession(host: firstHost)
        let first = try #require(workspace.focusedPane.sshSession)
        let peer = Pane.sshSession(host: secondHost)
        let second = try #require(peer.sshSession)
        workspace.splitFocusedPane(axis: .horizontal, with: peer)
        first.status = .connected
        second.status = .connected
        let app = AppModel(hosts: HostLibraryModel(hosts: [firstHost, secondHost]))
        let navigation = WindowModel(workspaces: [workspace])
        defer { app.shutdownForTermination() }
        let host = NSHostingView(
            rootView: WorkspaceContentView(workspace: workspace, isActive: true)
                .environment(app).environment(navigation).frame(width: 800, height: 400))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let firstSurface = try #require(first.terminalState.surface)
        let secondSurface = try #require(second.terminalState.surface)
        let firstSize = first.terminalState.surfaceSize
        let firstController = first.terminalState.controller
        let initial = first.terminalState.backgroundColor
        let peerColor = second.terminalState.backgroundColor
        guard case .inMemory(let backend) = first.terminalState.configuration.backend else {
            Issue.record("Expected an in-memory terminal")
            return
        }

        backend.receive("\u{1B}]11;#123456\u{07}")
        backend.waitForPendingOutput()
        let changed = TerminalColor(red: 0x12, green: 0x34, blue: 0x56)
        try await expectPixel(in: host, x: 200, y: 10, color: changed)
        #expect(first.terminalState.backgroundColor == changed)
        try await expectPixel(in: host, x: 600, y: 10, color: peerColor)
        #expect(second.terminalState.backgroundColor == peerColor)

        backend.receive("\u{1B}]111\u{07}")
        backend.waitForPendingOutput()
        try await expectPixel(in: host, x: 200, y: 10, color: initial)
        #expect(first.terminalState.backgroundColor == initial)
        #expect(first.terminalState.surface === firstSurface)
        #expect(second.terminalState.surface === secondSurface)
        #expect(first.terminalState.controller === firstController)
        #expect(first.terminalState.surfaceSize == firstSize)
    }

    private func expectPixel(in view: NSView, x: Int, y: Int, color: TerminalColor) async throws {
        // Keep the same hosted view mounted across updates: a fresh ImageRenderer
        // would read the new value even if the view forgot to subscribe to it.
        let reference = NSHostingView(
            rootView: Color(
                .sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
                blue: Double(color.blue) / 255, opacity: 1
            ).frame(width: 20, height: 20))
        reference.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        var referenceWindow: NSWindow?
        if let window = view.window {
            let sample = NSWindow(
                contentRect: reference.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            sample.isReleasedWhenClosed = false
            sample.colorSpace = window.colorSpace
            sample.appearance = window.effectiveAppearance
            sample.contentView = reference
            referenceWindow = sample
        }
        defer {
            referenceWindow?.contentView = nil
            referenceWindow?.close()
        }
        try await Task.sleep(for: .milliseconds(100))
        // Compare to a static swatch drawn through the same display color space;
        // cacheDisplay's calibrated RGB tagging varies between windowed and detached views.
        let bitmap = try snapshot(view)
        let expected = try #require(try snapshot(reference).colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        let scaleX = Double(bitmap.pixelsWide) / view.bounds.width
        let scaleY = Double(bitmap.pixelsHigh) / view.bounds.height
        let actual = try #require(
            bitmap.colorAt(x: Int(Double(x) * scaleX), y: Int(Double(y) * scaleY))?.usingColorSpace(.sRGB))
        let matches =
            abs(actual.redComponent - expected.redComponent) < 0.015
            && abs(actual.greenComponent - expected.greenComponent) < 0.015
            && abs(actual.blueComponent - expected.blueComponent) < 0.015
        if !matches {
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(data, named: "terminal-background-\(x)-\(color.red).png")
        }
        #expect(matches, "Pixel (\(x), \(y)): \(actual), expected \(color)")
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
