// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import GlyphixTextFx
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct WelcomeContextMenuTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func recentMenuKeepsItsWidthDuringGreetingTransition(language: String) async throws {
        let deviceID = UUID()
        let host = Host(name: "Production", host: "server.invalid")
        let app = AppModel(
            hosts: HostLibraryModel(hosts: [host]),
            connectionHistory: ConnectionHistoryModel(
                entries: [
                    ConnectionHistoryEntry(
                        hostID: host.id, kind: .ssh, connectedAt: .now, sourceDeviceID: deviceID)
                ], sourceDeviceID: deviceID))
        let view = NSHostingView(
            rootView: WelcomeView().environment(app).environment(WindowModel())
                .environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 680, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.sizingOptions = []
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()

        let menuView = try #require(
            descendants(view).compactMap { $0 as? NativeRowContextMenu.RowMenuView }.first)
        let menu = try #require(menuView.makeMenu())
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: menuView.convert(CGPoint(x: menuView.bounds.midX, y: menuView.bounds.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let label = try #require(descendants(view).compactMap { $0 as? GlyphixTextLabel }.first)
        let sample = MenuWidthSample(menu: menu, event: event, view: menuView, label: label)
        NotificationCenter.default.addObserver(
            sample, selector: #selector(MenuWidthSample.menuBegan(_:)), name: NSMenu.didBeginTrackingNotification,
            object: nil)
        defer { NotificationCenter.default.removeObserver(sample) }
        let firstTimer = Timer(timeInterval: 0.25, repeats: false) { _ in
            MainActor.assumeIsolated {
                sample.initial = sample.popupWindow?.frame.width
                sample.initialText = sample.label.text
            }
        }
        let lastTimer = Timer(timeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated {
                sample.final = sample.popupWindow?.frame.width
                sample.finalText = sample.label.text
                sample.menu.cancelTracking()
            }
        }
        defer {
            firstTimer.invalidate()
            lastTimer.invalidate()
        }
        RunLoop.main.add(firstTimer, forMode: .common)
        RunLoop.main.add(lastTimer, forMode: .common)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    sample.view.rightMouseDown(with: sample.event)
                    continuation.resume()
                }
            }
        }
        let initial = try #require(sample.initial)
        let final = try #require(sample.final)
        #expect(initial > 0)
        #expect(abs(initial - final) < 1)
        #expect(sample.initialText != sample.finalText)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
private final class MenuWidthSample: NSObject {
    var menu: NSMenu
    let event: NSEvent
    let view: NSView
    let label: GlyphixTextLabel
    var initialText: String?
    var finalText: String?

    init(menu: NSMenu, event: NSEvent, view: NSView, label: GlyphixTextLabel) {
        self.menu = menu
        self.event = event
        self.view = view
        self.label = label
    }

    @objc func menuBegan(_ notification: Notification) {
        if let menu = notification.object as? NSMenu {
            self.menu = menu
        }
    }

    // NSMenu.size keeps reporting the original width even when the popup shrinks.
    // Measure the actual window that AppKit displays throughout tracking.
    var popupWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)) == "NSPopupMenuWindow" }
    }

    var initial: CGFloat?
    var final: CGFloat?
}
