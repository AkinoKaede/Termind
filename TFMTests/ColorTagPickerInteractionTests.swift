// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Observation
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct ColorTagPickerInteractionTests {
    @Test(arguments: [ColorTagPicker.Layout.compact, .touch])
    func clickingSwatchesSelectsRepeatsAndClearsColors(layout: ColorTagPicker.Layout) async throws {
        let state = Selection()
        var pickerFrame = CGRect.zero
        let controller = NSHostingController(
            rootView: ColorTagPicker(
                selection: Binding(
                    get: { state.color },
                    set: {
                        state.color = $0
                        state.writes.append($0)
                    }),
                layout: layout
            )
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("palette.test"))
            } action: {
                pickerFrame = $0
            }
            .environment(\.locale, Locale(identifier: "en"))
            .frame(width: 300)
            .padding(24)
            .frame(width: 348, height: 180, alignment: .top)
            .coordinateSpace(name: "palette.test"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 348, height: 180)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutSubtreeIfNeeded()

        #expect(pickerFrame.width > 0 && pickerFrame.height > 0)
        for tag in [TagColor.yellow, .yellow, .purple, .none] {
            let index = try #require(TagColor.allCases.firstIndex(of: tag))
            let point: CGPoint
            if layout == .compact {
                point = CGPoint(x: pickerFrame.minX + 10 + CGFloat(index) * 28, y: pickerFrame.midY)
            } else {
                let columns = Int((pickerFrame.width + 4) / 48)
                let cellWidth = (pickerFrame.width - CGFloat(columns - 1) * 4) / CGFloat(columns)
                point = CGPoint(
                    x: pickerFrame.minX + cellWidth / 2 + CGFloat(index % columns) * (cellWidth + 4),
                    y: pickerFrame.minY + 22 + CGFloat(index / columns) * 52)
            }
            try click(point, in: controller.view, window: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(state.color == tag)
        }
        #expect(state.writes == [.yellow, .yellow, .purple, .none])
    }

    private func click(_ point: CGPoint, in view: NSView, window: NSWindow) throws {
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: false)
        }
        let deadline = Date(timeIntervalSinceNow: 0.2)
        while Date() < deadline {
            if let event = NSApp.nextEvent(
                matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }
    }

    @Observable @MainActor
    fileprivate final class Selection {
        var color = TagColor.red
        var writes: [TagColor] = []
    }
}
