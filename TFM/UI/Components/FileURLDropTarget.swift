import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#endif

nonisolated struct LocalFileDropRequest: Identifiable, Sendable {
    let id = UUID()
    let urls: [URL]
}

nonisolated struct SFTPRemoteDropRequest: Identifiable, Sendable {
    let id = UUID()
    let data: Data
}

nonisolated enum NativeDropKind: Hashable, Sendable {
    case files
    case images
    case sftpItems
    case terminalPath
}

nonisolated struct NativeDropPayload: Sendable {
    var fileURLs: [URL] = []
    var images: [Data] = []
    var sftpItems: Data?
    var terminalPath: String?

    var preferredKind: NativeDropKind? {
        if sftpItems != nil { return .sftpItems }
        if terminalPath != nil { return .terminalPath }
        if !fileURLs.isEmpty { return .files }
        if !images.isEmpty { return .images }
        return nil
    }

    func restricted(to acceptedKinds: Set<NativeDropKind>) -> NativeDropPayload {
        NativeDropPayload(
            fileURLs: acceptedKinds.contains(.files) ? fileURLs : [],
            images: acceptedKinds.contains(.images) ? images : [],
            sftpItems: acceptedKinds.contains(.sftpItems) ? sftpItems : nil,
            terminalPath: acceptedKinds.contains(.terminalPath) ? terminalPath : nil
        )
    }
}

#if canImport(AppKit)
    /// A native receiver that stays above AppKit-backed terminal, table, and
    /// transcript views without stealing their ordinary pointer interaction.
    struct NativeDropTarget: NSViewRepresentable {
        @Binding var targetedKind: NativeDropKind?
        let acceptedKinds: Set<NativeDropKind>
        let isEnabled: Bool
        let receive: (NativeDropPayload) -> Bool

        func makeNSView(context _: Context) -> FileURLDropNSView {
            FileURLDropNSView(
                acceptedKinds: acceptedKinds,
                isEnabled: isEnabled,
                targetedKind: setTargeted,
                receivePayload: receive
            )
        }

        func updateNSView(_ view: FileURLDropNSView, context _: Context) {
            view.acceptedKinds = acceptedKinds
            view.targetedKind = setTargeted
            view.isEnabled = isEnabled
            view.receivePayload = receive
        }

        private func setTargeted(_ kind: NativeDropKind?) {
            targetedKind = kind
        }
    }

    final class FileURLDropNSView: NSView {
        var acceptedKinds: Set<NativeDropKind>

        /// Whether this receiver is the one on screen.
        ///
        /// Layers that are mounted but invisible keep their drop targets alive —
        /// the Assistant panel holds the Workspace layer behind the sidebar chat
        /// list, and every Workspace stays in the deck at `opacity(0)`. AppKit
        /// honours neither `allowsHitTesting(false)` nor `opacity(0)` when it
        /// looks for a drag destination, so a hidden copy used to win the drop
        /// and file it somewhere nobody could see.
        ///
        /// Both halves of the retreat are needed, for the same reasons spelled
        /// out on `AssistantConversationListContainer.isInteractive`: leaving
        /// this view in the window's registered destination list hands it drags
        /// it refused by hit test, and unregistering cannot reach a drag already
        /// in flight, because AppKit resolved its destinations when the drag
        /// began. `supportedPayload(from:)` is the second half — every entry
        /// point passes through it.
        var isEnabled: Bool {
            didSet {
                guard isEnabled != oldValue else { return }
                if isEnabled {
                    registerForDraggedTypes(Self.registeredTypes)
                } else {
                    unregisterDraggedTypes()
                }
            }
        }

        var targetedKind: (NativeDropKind?) -> Void
        var receivePayload: (NativeDropPayload) -> Bool

        init(
            acceptedKinds: Set<NativeDropKind>,
            isEnabled: Bool = true,
            targetedKind: @escaping (NativeDropKind?) -> Void,
            receivePayload: @escaping (NativeDropPayload) -> Bool
        ) {
            self.acceptedKinds = acceptedKinds
            self.isEnabled = isEnabled
            self.targetedKind = targetedKind
            self.receivePayload = receivePayload
            super.init(frame: .zero)
            // Registered here rather than left to `isEnabled`: a property
            // assigned in `init` does not run its own `didSet`.
            if isEnabled { registerForDraggedTypes(Self.registeredTypes) }
        }

        convenience init(
            isEnabled: Bool = true,
            isTargeted: @escaping (Bool) -> Void,
            receive: @escaping ([URL]) -> Bool
        ) {
            self.init(
                acceptedKinds: [.files],
                isEnabled: isEnabled,
                targetedKind: { isTargeted($0 != nil) },
                receivePayload: { receive($0.fileURLs) }
            )
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError() }

        override var isOpaque: Bool { false }

        /// Finder drags do not arrive as `NSApp.currentEvent ==
        /// .leftMouseDragged`; inspect the drag pasteboard, but explicitly let
        /// every ordinary control event pass through this full-surface view.
        override func hitTest(_ point: NSPoint) -> NSView? {
            participates(
                at: point,
                currentEventType: NSApp.currentEvent?.type,
                pasteboard: NSPasteboard(name: .drag)
            ) ? self : nil
        }

        /// The decision `hitTest` makes, with its two ambient inputs passed in.
        ///
        /// `NSApp.currentEvent` and the `.drag` pasteboard are both process-wide
        /// and, in the pasteboard's case, machine-wide. Reading them here rather
        /// than in `hitTest` keeps the rule itself checkable: a caller supplies
        /// the event type and pasteboard it means to ask about instead of
        /// arranging for the whole application to be in the right state.
        func participates(
            at point: NSPoint,
            currentEventType: NSEvent.EventType?,
            pasteboard: NSPasteboard
        ) -> Bool {
            isEnabled
                && bounds.contains(point)
                && !Self.isOrdinaryPointerEvent(currentEventType)
                && supportedPayload(from: pasteboard) != nil
        }

        /// `.drag` retains its last contents, so a stale file or bitmap must
        /// never make this transparent receiver capture normal interaction.
        static func isOrdinaryPointerEvent(_ type: NSEvent.EventType?) -> Bool {
            switch type {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .mouseMoved, .cursorUpdate,
                .scrollWheel:
                true
            default:
                false
            }
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let payload = supportedPayload(from: sender.draggingPasteboard) else {
                targetedKind(nil)
                return []
            }
            targetedKind(payload.preferredKind)
            return .copy
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let payload = supportedPayload(from: sender.draggingPasteboard) else {
                targetedKind(nil)
                return []
            }
            targetedKind(payload.preferredKind)
            return .copy
        }

        override func draggingExited(_: (any NSDraggingInfo)?) {
            targetedKind(nil)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { targetedKind(nil) }
            guard let payload = supportedPayload(from: sender.draggingPasteboard) else {
                return false
            }
            return receivePayload(payload)
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            targetedKind(nil)
            super.concludeDragOperation(sender)
        }

        /// The one gate `hitTest` and all three dragging callbacks pass through.
        /// A disabled receiver answers nil to each, which already means "not
        /// mine" everywhere: the two `dragging*` methods clear the highlight and
        /// return no operation, and `performDragOperation` declines. See
        /// `isEnabled` for why refusing the hit test is not enough on its own.
        func supportedPayload(from pasteboard: NSPasteboard) -> NativeDropPayload? {
            guard isEnabled else { return nil }
            let payload = Self.payload(
                from: pasteboard,
                preferSFTPItems: acceptedKinds.contains(.sftpItems)
            ).restricted(to: acceptedKinds)
            return payload.preferredKind == nil ? nil : payload
        }

        static func payload(
            from pasteboard: NSPasteboard,
            preferSFTPItems: Bool = true
        ) -> NativeDropPayload {
            let sftpType = NSPasteboard.PasteboardType(UTType.termindSFTPItems.identifier)
            let sftpItems = pasteboard.data(forType: sftpType)
            if preferSFTPItems, let sftpItems {
                // The same provider also advertises a promised local file for
                // Finder. Asking that representation for a URL materializes
                // the promise and starts a download. An in-app SFTP target
                // must consume only the private payload, otherwise one drag
                // creates both a remote copy and a redundant download/upload.
                return NativeDropPayload(sftpItems: sftpItems)
            }
            if let text = TerminalPathDrag.text(from: pasteboard) {
                return NativeDropPayload(terminalPath: text)
            }
            var payload = NativeDropPayload(sftpItems: sftpItems)

            for item in pasteboard.pasteboardItems ?? [] {
                if let value = item.string(forType: .fileURL),
                    let url = URL(string: value), url.isFileURL
                {
                    // Finder images also advertise bitmap representations. The
                    // URL preserves the real filename and must win per item.
                    payload.fileURLs.append(url)
                    continue
                }

                guard
                    let type = item.types.first(where: { type in
                        UTType(type.rawValue)?.conforms(to: .image) == true
                    }), let data = item.data(forType: type)
                else { continue }
                payload.images.append(data)
            }
            return payload
        }

        private static let registeredTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.image.identifier),
            NSPasteboard.PasteboardType(UTType.png.identifier),
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.tiff.identifier),
            NSPasteboard.PasteboardType(UTType.heic.identifier),
            NSPasteboard.PasteboardType(UTType.termindSFTPItems.identifier),
            TerminalPathDrag.pasteboardType,
        ]
    }
#endif
