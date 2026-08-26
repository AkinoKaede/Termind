import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

nonisolated struct LocalFileDropRequest: Identifiable, Sendable {
    let id = UUID()
    let urls: [URL]
}

#if canImport(AppKit)
    struct NativeFileURLDropTarget: NSViewRepresentable {
        @Binding var isTargeted: Bool
        let isEnabled: Bool
        let receive: ([URL]) -> Bool

        func makeNSView(context _: Context) -> FileURLDropNSView {
            FileURLDropNSView(
                isEnabled: isEnabled, isTargeted: setTargeted, receive: receive
            )
        }

        func updateNSView(_ view: FileURLDropNSView, context _: Context) {
            view.isTargeted = setTargeted
            view.isEnabled = isEnabled
            view.receive = receive
        }

        private func setTargeted(_ targeted: Bool) {
            isTargeted = targeted
        }
    }

    final class FileURLDropNSView: NSView {
        var isEnabled: Bool
        var isTargeted: (Bool) -> Void
        var receive: ([URL]) -> Bool

        init(
            isEnabled: Bool = true,
            isTargeted: @escaping (Bool) -> Void,
            receive: @escaping ([URL]) -> Bool
        ) {
            self.isEnabled = isEnabled
            self.isTargeted = isTargeted
            self.receive = receive
            super.init(frame: .zero)
            registerForDraggedTypes([.fileURL])
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError() }

        override var isOpaque: Bool { false }

        /// Finder drags do not arrive as `NSApp.currentEvent ==
        /// .leftMouseDragged`; that test only describes a drag originating in
        /// this process. Inspecting the drag pasteboard makes the view present
        /// only for external file drags and transparent to ordinary controls.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard
                isEnabled,
                bounds.contains(point),
                !Self.isOrdinaryPointerEvent(NSApp.currentEvent?.type),
                Self.hasSupportedDragPasteboard
            else {
                return nil
            }
            return self
        }

        /// `.drag` is a named pasteboard, not an "is dragging" flag. Finder can
        /// leave its last file URL there after a drop, so pasteboard contents
        /// alone must never make this full-composer view win normal hit tests.
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
            guard !fileURLs(from: sender).isEmpty else { return [] }
            isTargeted(true)
            return .copy
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            fileURLs(from: sender).isEmpty ? [] : .copy
        }

        override func draggingExited(_: (any NSDraggingInfo)?) {
            isTargeted(false)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            isTargeted(false)
            let urls = fileURLs(from: sender)
            return !urls.isEmpty && receive(urls)
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            isTargeted(false)
            super.concludeDragOperation(sender)
        }

        private static var hasSupportedDragPasteboard: Bool {
            NSPasteboard(name: .drag).availableType(from: [.fileURL]) != nil
        }

        private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
            sender.draggingPasteboard.pasteboardItems?.compactMap { item in
                guard let value = item.string(forType: .fileURL),
                    let url = URL(string: value), url.isFileURL
                else { return nil }
                return url
            } ?? []
        }
    }
#endif
