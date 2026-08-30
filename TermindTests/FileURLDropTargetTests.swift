#if canImport(AppKit)
    import AppKit
    import Testing
    import UniformTypeIdentifiers
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

        @Test
        func bitmapDataDoesNotMakeNativeTargetCaptureComposerInput() {
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.clearContents()
            defer { pasteboard.clearContents() }
            let target = FileURLDropNSView(isTargeted: { _ in }, receive: { _ in false })
            target.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
            let point = CGPoint(x: 50, y: 50)

            pasteboard.setData(Data([1, 2, 3]), forType: .tiff)

            #expect(target.hitTest(point) == nil)
        }

        @Test
        func generalizedTargetRecognizesBitmapAndSFTPItemsSeparately() throws {
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.clearContents()
            defer { pasteboard.clearContents() }

            let target = FileURLDropNSView(
                acceptedKinds: [.images, .sftpItems],
                targetedKind: { _ in },
                receivePayload: { _ in true }
            )

            pasteboard.setData(Data([1, 2, 3]), forType: .tiff)
            #expect(target.supportedPayload(from: pasteboard)?.preferredKind == .images)

            let remote = try JSONEncoder().encode(SFTPRemoteItemsPayload(token: UUID()))
            pasteboard.setData(
                remote,
                forType: NSPasteboard.PasteboardType(UTType.termindSFTPItems.identifier)
            )
            #expect(target.supportedPayload(from: pasteboard)?.preferredKind == .sftpItems)
        }

        @Test
        func finderImagePrefersItsFileURLAndFilename() throws {
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.clearContents()
            defer { pasteboard.clearContents() }
            let item = NSPasteboardItem()
            let url = URL(fileURLWithPath: "/tmp/screenshot.png")
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(Data([1, 2, 3]), forType: .tiff)
            pasteboard.writeObjects([item])

            let payload = FileURLDropNSView.payload(from: pasteboard)

            #expect(payload.fileURLs == [url])
            #expect(payload.images.isEmpty)
            #expect(payload.preferredKind == .files)
        }

        @Test
        func staleFileURLPasteboardCannotCaptureNormalComposerInteraction() {
            #expect(FileURLDropNSView.isOrdinaryPointerEvent(.leftMouseDown))
            #expect(FileURLDropNSView.isOrdinaryPointerEvent(.leftMouseUp))
            #expect(FileURLDropNSView.isOrdinaryPointerEvent(.mouseMoved))
            #expect(FileURLDropNSView.isOrdinaryPointerEvent(.cursorUpdate))
            #expect(FileURLDropNSView.isOrdinaryPointerEvent(.scrollWheel))
            #expect(!FileURLDropNSView.isOrdinaryPointerEvent(.applicationDefined))
        }
    }
#endif
