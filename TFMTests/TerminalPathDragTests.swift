import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Termind

@Suite @MainActor
struct TerminalPathDragTests {
    @Test
    func providerCarriesTheFullEscapedPathWithoutAdvertisingAFile() async throws {
        let path = "/home/user/中文/my files/it's live"
        let provider = TerminalPathDrag.provider(for: path)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: TerminalPathDrag.type.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(data, forType: TerminalPathDrag.pasteboardType)
        #expect(TerminalPathDrag.text(from: pasteboard) == #"/home/user/中文/my\ files/it\'s\ live"#)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        #expect(FileURLDropNSView.payload(from: pasteboard).restricted(to: [.files, .sftpItems]).preferredKind == nil)
    }

    @Test
    func plainTextFileURLsAndInvalidDataAreNotPathInsertions() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("/srv/plain text", forType: .string)
        pasteboard.setString("file:///srv/file", forType: .fileURL)
        #expect(TerminalPathDrag.text(from: pasteboard) == nil)
        pasteboard.setData(Data([0xFF]), forType: TerminalPathDrag.pasteboardType)
        #expect(TerminalPathDrag.text(from: pasteboard) == nil)
        pasteboard.setData(Data(), forType: TerminalPathDrag.pasteboardType)
        #expect(TerminalPathDrag.text(from: pasteboard) == nil)
    }

    @Test
    func unmountedTerminalRefusesPathDrops() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("/srv/path", forType: TerminalPathDrag.pasteboardType)
        let view = TermindTerminalView(frame: .zero)
        view.setSurfaceVisible(true)
        #expect(!view.registeredDraggedTypes.contains(TerminalPathDrag.pasteboardType))
        #expect(view.pathDropOperation(from: pasteboard, sourceOperations: .copy).isEmpty)
        #expect(!view.receivePathDrop(from: pasteboard, sourceOperations: .copy))
    }
}
