import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#endif

nonisolated struct LocalFileDropRequest: Identifiable, Sendable {
    let id = UUID()
    let urls: [URL]
}

/// Receives Finder drags through their concrete pasteboard representation.
///
/// `dropDestination(for: URL.self)` relies on Transferable inference. Finder
/// advertises dragged files as `public.file-url`, and that inference is not
/// reliable for every Finder/macOS combination. Loading the item providers
/// explicitly also keeps this path separate from Termind's internal drags.
struct FileURLDropTarget: DropDelegate {
    @Binding var isTargeted: Bool
    let receive: ([URL]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        FileURLDropLoader.load(providers, receive: receive)
        return true
    }
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
            guard isEnabled, bounds.contains(point), Self.hasFileURLsOnDragPasteboard else {
                return nil
            }
            return self
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

        private static var hasFileURLsOnDragPasteboard: Bool {
            NSPasteboard(name: .drag).availableType(from: [.fileURL]) != nil
        }

        private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            return (sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: options
            ) as? [URL]) ?? []
        }
    }
#endif

private enum FileURLDropLoader {
    static func load(_ providers: [NSItemProvider], receive: @escaping ([URL]) -> Bool) {
        let results = FileURLDropResults(count: providers.count)
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                if let url = fileURL(from: item) {
                    results.set(url, at: index)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            _ = receive(results.urls)
        }
    }

    nonisolated static func fileURL(from item: (any NSSecureCoding)?) -> URL? {
        let url: URL?
        switch item {
        case let value as URL:
            url = value
        case let value as NSURL:
            url = value as URL
        case let value as Data:
            url = URL(dataRepresentation: value, relativeTo: nil)
        case let value as String:
            url = URL(string: value)
        default:
            url = nil
        }
        return url?.isFileURL == true ? url : nil
    }
}

private nonisolated final class FileURLDropResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func set(_ url: URL, at index: Int) {
        lock.withLock { storage[index] = url }
    }

    var urls: [URL] {
        lock.withLock { storage.compactMap(\.self) }
    }
}
