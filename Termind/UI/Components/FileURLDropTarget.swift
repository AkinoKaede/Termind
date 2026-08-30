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
}

nonisolated struct NativeDropPayload: Sendable {
    var fileURLs: [URL] = []
    var images: [Data] = []
    var sftpItems: Data?

    var preferredKind: NativeDropKind? {
        if sftpItems != nil { return .sftpItems }
        if !fileURLs.isEmpty { return .files }
        if !images.isEmpty { return .images }
        return nil
    }

    func restricted(to acceptedKinds: Set<NativeDropKind>) -> NativeDropPayload {
        NativeDropPayload(
            fileURLs: acceptedKinds.contains(.files) ? fileURLs : [],
            images: acceptedKinds.contains(.images) ? images : [],
            sftpItems: acceptedKinds.contains(.sftpItems) ? sftpItems : nil
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

    /// Kept as a narrow convenience for call sites that only accept Finder
    /// URLs. New full-surface destinations use `NativeDropTarget` directly.
    struct NativeFileURLDropTarget: NSViewRepresentable {
        @Binding var isTargeted: Bool
        let isEnabled: Bool
        let receive: ([URL]) -> Bool

        func makeNSView(context _: Context) -> FileURLDropNSView {
            FileURLDropNSView(
                isEnabled: isEnabled,
                isTargeted: setTargeted,
                receive: receive
            )
        }

        func updateNSView(_ view: FileURLDropNSView, context _: Context) {
            view.acceptedKinds = [.files]
            view.targetedKind = { setTargeted($0 != nil) }
            view.isEnabled = isEnabled
            view.receivePayload = { receive($0.fileURLs) }
        }

        private func setTargeted(_ targeted: Bool) {
            isTargeted = targeted
        }
    }

    final class FileURLDropNSView: NSView {
        var acceptedKinds: Set<NativeDropKind>
        var isEnabled: Bool
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
            registerForDraggedTypes(Self.registeredTypes)
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
            guard
                isEnabled,
                bounds.contains(point),
                !Self.isOrdinaryPointerEvent(NSApp.currentEvent?.type),
                supportedPayload(from: NSPasteboard(name: .drag)) != nil
            else {
                return nil
            }
            return self
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

        func supportedPayload(from pasteboard: NSPasteboard) -> NativeDropPayload? {
            let payload = Self.payload(from: pasteboard).restricted(to: acceptedKinds)
            return payload.preferredKind == nil ? nil : payload
        }

        static func payload(from pasteboard: NSPasteboard) -> NativeDropPayload {
            let sftpType = NSPasteboard.PasteboardType(UTType.termindSFTPItems.identifier)
            var payload = NativeDropPayload(sftpItems: pasteboard.data(forType: sftpType))

            for item in pasteboard.pasteboardItems ?? [] {
                if let value = item.string(forType: .fileURL),
                    let url = URL(string: value), url.isFileURL
                {
                    // Finder images also advertise bitmap representations. The
                    // URL preserves the real filename and must win per item.
                    payload.fileURLs.append(url)
                    continue
                }

                guard let type = item.types.first(where: { type in
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
        ]
    }
#endif
