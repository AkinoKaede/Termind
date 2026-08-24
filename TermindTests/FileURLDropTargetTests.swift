#if canImport(AppKit)
    import AppKit
    import Testing
    @testable import Termind

    @MainActor
    struct FileURLDropTargetTests {
        @Test
        func nativeTargetOnlyParticipatesWhenDragPasteboardContainsAFileURL() throws {
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.clearContents()
            defer { pasteboard.clearContents() }

            let target = FileURLDropNSView(isTargeted: { _ in }, receive: { _ in true })
            target.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
            let point = CGPoint(x: 50, y: 50)

            #expect(target.hitTest(point) == nil)

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("termind-drop-target-test.txt")
            try Data("probe".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(pasteboard.writeObjects([file as NSURL]))

            #expect(target.hitTest(point) === target)
        }
    }
#endif
