import AppKit
import TermindDomain
import UniformTypeIdentifiers

/// A path insertion carries shell text, never a file URL or an SFTP copy token.
enum TerminalPathDrag {
    static let type = UTType(exportedAs: "com.akinokaede.termind.terminal-path", conformingTo: .utf8PlainText)
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)

    static func provider(for path: String) -> NSItemProvider {
        let text = RemoteShellCommand.escapeArgument(path)
        let provider = NSItemProvider(object: text as NSString)
        let data = Data(text.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func text(from pasteboard: NSPasteboard) -> String? {
        guard let data = pasteboard.data(forType: pasteboardType),
            let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }
}
