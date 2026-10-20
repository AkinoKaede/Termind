// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Observes cancellation without participating in the native List's gesture
/// recognition. Escape stays latched through its failed-drop return animation.
@MainActor
final class WorkspaceDragCancellationTracker {
    private var observer: CFRunLoopObserver?
    private var keyMonitor: Any?
    private var wasCancelled = false

    func begin() {
        guard observer == nil else { return }
        wasCancelled = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.recordEscape() }
            return event
        }
        // AppKit's drag tracking loop can consume Escape before local event
        // monitors receive it. Observe key state within that loop as well.
        observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.allActivities.rawValue, true, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                if CGEventSource.keyState(.combinedSessionState, key: 53) {
                    self?.recordEscape()
                }
            }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopAddObserver(
                CFRunLoopGetMain(), observer,
                CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString)
            )
        }
    }

    func recordEscape() {
        wasCancelled = true
    }

    @discardableResult
    func end() -> Bool {
        stopObserving()
        return wasCancelled
    }

    private func stopObserving() {
        if let observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    isolated deinit {
        stopObserving()
    }
}
