import Foundation
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindPresentation

/// Marks the synchronous part of an AppKit terminal interaction.
///
/// Ghostty's in-memory backend uses one callback for everything written toward
/// the host: keyboard input, paste bytes, mouse reports, focus reports, and
/// terminal protocol replies. Broadcast Input must copy only the first two.
/// The native view enters this scope around keyboard/AppKit paste handling, and
/// the backend callback consumes its synchronous or short-lived deferred ticket
/// before hopping back to MainActor.
nonisolated final class TerminalInteractiveInputCapture: @unchecked Sendable {
    private static let deferredWriteWindowNanoseconds: UInt64 = 100_000_000
    private let lock = NSLock()
    private var depth = 0
    private var localPasteDepth = 0
    private var writeGeneration: UInt64 = 0
    private var deferredWriteDeadline: UInt64?
    private var bracketedPaste: (tail: Data, deadline: UInt64)?
    private static let pasteStart = Data("\u{1B}[200~".utf8)
    private static let pasteEnd = Data("\u{1B}[201~".utf8)

    var isActive: Bool {
        lock.withLock { depth > 0 }
    }

    func withInteraction<Result>(
        allowsDeferredWrite: Bool = true,
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let generation = lock.withLock { () -> UInt64 in
            depth += 1
            return writeGeneration
        }
        defer {
            lock.withLock {
                depth -= 1
                guard allowsDeferredWrite, writeGeneration == generation else { return }
                deferredWriteDeadline =
                    DispatchTime.now().uptimeNanoseconds
                    &+ Self.deferredWriteWindowNanoseconds
            }
        }
        return try operation()
    }

    /// A completed upload inserts into its original session even during broadcast.
    func withLocalPaste<T>(_ operation: () throws -> T) rethrows -> T {
        lock.withLock {
            localPasteDepth += 1
            deferredWriteDeadline = nil
            bracketedPaste = nil
        }
        defer { lock.withLock { localPasteDepth -= 1 } }
        return try operation()
    }

    /// Classifies the backend callback while it still has the input event's
    /// provenance. Ordinarily Ghostty writes synchronously. The short-lived
    /// deferred ticket covers callbacks it schedules just after AppKit returns.
    /// A bracketed paste can arrive as separate opening, body, and closing writes;
    /// retain its provenance through the closing marker, even across callbacks.
    /// Both the initial ticket and an interrupted paste expire promptly.
    func classifyWrite(_ data: Data = Data()) -> Bool {
        lock.withLock {
            writeGeneration &+= 1
            guard localPasteDepth == 0 else { return false }
            let now = DispatchTime.now().uptimeNanoseconds
            if let paste = bracketedPaste, now > paste.deadline {
                bracketedPaste = nil
            }
            let isInteractive =
                depth > 0 || bracketedPaste != nil
                || deferredWriteDeadline.map { now <= $0 } == true
            deferredWriteDeadline = nil
            guard isInteractive else { return false }

            let pasteBytes: Data
            if let paste = bracketedPaste {
                pasteBytes = paste.tail + data
            } else if data.starts(with: Self.pasteStart) {
                pasteBytes = Data(data.dropFirst(Self.pasteStart.count))
            } else {
                return true
            }
            if pasteBytes.range(of: Self.pasteEnd) != nil {
                bracketedPaste = nil
            } else {
                // Keep a bounded tail to recognize a split closing marker.
                bracketedPaste = (
                    Data(pasteBytes.suffix(Self.pasteEnd.count - 1)),
                    now &+ Self.deferredWriteWindowNanoseconds
                )
            }
            return true
        }
    }
}

private struct DesktopTerminalChrome: ViewModifier {
    let state: TerminalViewState
    @TerminalAppearanceSettings private var appearance

    func body(content: Content) -> some View {
        content
            .background { TerminalBackground(state: state) }
            .onAppear {
                state.applyPreferences(appearance.preferences, font: appearance.font)
            }
            .onChange(of: appearance) { _, value in
                state.applyPreferences(value.preferences, font: value.font)
            }
    }
}

extension View {
    func desktopTerminalChrome(state: TerminalViewState) -> some View {
        modifier(DesktopTerminalChrome(state: state))
    }
}

/// Common presentation for terminal transports that need only a Journey with
/// Retry/Close actions. SSH keeps its richer authentication and upload chrome.
struct SimpleDesktopTerminalView: View {
    let state: TerminalViewState
    let owner: PersistentTerminalViewOwner
    let journey: ConnectionJourney
    let isVisible: Bool
    let requestsFocus: Bool
    let connectIfNeeded: () -> Void
    let retry: () -> Void
    let requestFocus: () -> Void
    let closePane: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool

    var body: some View {
        PersistentTerminalSurfaceView(
            state: state,
            owner: owner,
            isVisible: isVisible,
            requestsFocus: requestsFocus && !journey.isPresented
        )
        .desktopTerminalChrome(state: state)
        .overlay { connectionJourney }
        .focused($focused)
        .onAppear {
            TerminalFontCatalog.shared.refresh()
            connectIfNeeded()
            if requestsFocus { requestFocus() }
        }
        .onChange(of: requestsFocus) { _, value in
            focused = value
            if value, !journey.isPresented { requestFocus() }
        }
        .onChange(of: journey.isPresented) { _, presented in
            if !presented, requestsFocus { requestFocus() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { TerminalFontCatalog.shared.refresh() }
        }
    }

    @ViewBuilder
    private var connectionJourney: some View {
        if isVisible, journey.isPresented {
            ConnectionJourneyView(
                journey: journey,
                submitAuthentication: { _, _, _, _, _, _ in },
                continueHostKey: { _ in },
                trustHostKey: { _ in },
                denyHostKey: closePane,
                retry: retry,
                cancel: closePane,
                failureCancelLabel: AppStrings.Common.close,
                failureRetryLabel: AppStrings.Terminal.reconnect,
                compactFailureActions: true
            )
        }
    }
}
