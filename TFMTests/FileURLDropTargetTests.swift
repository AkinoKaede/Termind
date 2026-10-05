import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

#if canImport(AppKit)
    import AppKit
    import Testing
    import UniformTypeIdentifiers
    @testable import Termind

    /// Every test here owns its pasteboard rather than staging its case on the
    /// one `.drag` pasteboard the whole machine shares, and asks
    /// `participates(at:currentEventType:pasteboard:)` rather than `hitTest`,
    /// which reads that pasteboard and `NSApp.currentEvent` for itself. Both
    /// are ambient: a neighbouring suite that activates the application, or a
    /// real drag anywhere on the Mac, used to decide the outcome here.
    @MainActor
    struct FileURLDropTargetTests {
        /// A pasteboard this test owns outright, cleaned up when it returns.
        private func stagedPasteboard() -> NSPasteboard {
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            return pasteboard
        }

        /// The event type in effect while a Finder drag is over the window —
        /// notably not one of the ordinary pointer events that must fall
        /// through to the control underneath.
        private static let dragEvent = NSEvent.EventType.leftMouseDragged

        @Test
        func terminalPaneOverlayClaimsPathDragsAndProposesCopyWithoutStartingATransfer() {
            let pasteboard = stagedPasteboard()
            defer { pasteboard.releaseGlobally() }
            let text = RemoteShellCommand.escapeArgument("/srv/中文/my files")
            pasteboard.setString(text, forType: TerminalPathDrag.pasteboardType)
            var received: [NativeDropPayload] = []
            let target = FileURLDropNSView(
                acceptedKinds: [.files, .sftpItems, .terminalPath],
                targetedKind: { _ in },
                receivePayload: {
                    received.append($0)
                    return true
                })
            target.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
            let drag = DraggingInfoStub(pasteboard: pasteboard)
            #expect(participation(target, pasteboard))
            #expect(!participation(target, pasteboard, event: .leftMouseDown))
            #expect(target.draggingEntered(drag) == .copy)
            #expect(target.draggingUpdated(drag) == .copy)
            #expect(target.performDragOperation(drag))
            #expect(received.count == 1)
            #expect(received.first?.terminalPath == text)
            #expect(received.first?.sftpItems == nil)
            #expect(received.first?.fileURLs.isEmpty == true)
            target.isEnabled = false
            #expect(!participation(target, pasteboard))
            #expect(target.draggingUpdated(drag).isEmpty)
            #expect(!target.performDragOperation(drag))
        }

        @Test
        func sftpDragsProposeTheCopyCursorAndDeliverOnlyTheRemotePayload() throws {
            let pasteboard = stagedPasteboard()
            defer { pasteboard.releaseGlobally() }
            let data = try JSONEncoder().encode(SFTPRemoteItemsPayload(token: UUID()))
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.termindSFTPItems.identifier))
            let drag = DraggingInfoStub(pasteboard: pasteboard)
            var targeted: NativeDropKind?
            var received: [NativeDropPayload] = []
            let target = FileURLDropNSView(
                acceptedKinds: [.files, .sftpItems],
                targetedKind: { targeted = $0 },
                receivePayload: {
                    received.append($0)
                    return true
                })

            #expect(target.draggingEntered(drag) == .copy)
            #expect(target.draggingUpdated(drag) == .copy)
            #expect(targeted == .sftpItems)
            #expect(received.isEmpty)
            #expect(target.performDragOperation(drag))
            #expect(received.count == 1)
            #expect(received.first?.sftpItems == data)
            #expect(received.first?.fileURLs.isEmpty == true)
            #expect(targeted == nil)

            target.isEnabled = false
            #expect(target.draggingEntered(drag).isEmpty)
            #expect(target.draggingUpdated(drag).isEmpty)
            #expect(!target.performDragOperation(drag))
            #expect(received.count == 1)
        }

        /// Asks the participation rule about a point inside the target, so each
        /// case below reads as one line instead of a four-line call.
        private func participation(
            _ target: FileURLDropNSView, _ pasteboard: NSPasteboard,
            event: NSEvent.EventType = FileURLDropTargetTests.dragEvent,
            at point: CGPoint = CGPoint(x: 50, y: 50)
        ) -> Bool {
            target.participates(at: point, currentEventType: event, pasteboard: pasteboard)
        }

        @Test
        func nativeTargetOnlyParticipatesWhenDragPasteboardContainsAFileURL() throws {
            let pasteboard = stagedPasteboard()
            defer { pasteboard.releaseGlobally() }

            let target = FileURLDropNSView(isTargeted: { _ in }, receive: { _ in true })
            target.frame = CGRect(x: 0, y: 0, width: 200, height: 100)

            #expect(!participation(target, pasteboard))

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("termind-drop-target-test.txt")
            try Data("probe".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(pasteboard.writeObjects([file as NSURL]))

            #expect(participation(target, pasteboard))
            // Same file still on the pasteboard: it is the event and the point,
            // not the contents, that keep this receiver out of the way.
            #expect(!participation(target, pasteboard, event: .leftMouseDown))
            #expect(!participation(target, pasteboard, at: CGPoint(x: 500, y: 500)))
        }

        @Test
        func bitmapDataDoesNotMakeNativeTargetCaptureComposerInput() {
            let pasteboard = stagedPasteboard()
            defer { pasteboard.releaseGlobally() }
            let target = FileURLDropNSView(isTargeted: { _ in }, receive: { _ in false })
            target.frame = CGRect(x: 0, y: 0, width: 200, height: 100)

            pasteboard.setData(Data([1, 2, 3]), forType: .tiff)

            #expect(!participation(target, pasteboard))
        }

        @Test
        func generalizedTargetRecognizesBitmapAndSFTPItemsSeparately() throws {
            let pasteboard = stagedPasteboard()
            defer { pasteboard.releaseGlobally() }

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
        func internalSFTPPayloadDoesNotRequestItsPromisedLocalFile() throws {
            let pasteboard = stagedPasteboard()
            defer { pasteboard.releaseGlobally() }
            let item = NSPasteboardItem()
            let remote = try JSONEncoder().encode(SFTPRemoteItemsPayload(token: UUID()))
            item.setData(
                remote,
                forType: NSPasteboard.PasteboardType(UTType.termindSFTPItems.identifier))
            item.setString(
                URL(fileURLWithPath: "/tmp/materialized-by-a-file-promise").absoluteString,
                forType: .fileURL)
            pasteboard.writeObjects([item])

            let payload = FileURLDropNSView.payload(from: pasteboard)

            #expect(payload.sftpItems == remote)
            #expect(payload.fileURLs.isEmpty)
            #expect(payload.preferredKind == .sftpItems)

            let fileOnlyPayload = FileURLDropNSView.payload(
                from: pasteboard, preferSFTPItems: false)
            #expect(fileOnlyPayload.fileURLs.count == 1)

            let terminalTarget = FileURLDropNSView(
                acceptedKinds: [.files, .sftpItems],
                targetedKind: { _ in },
                receivePayload: { _ in true }
            )
            let terminalPayload = try #require(terminalTarget.supportedPayload(from: pasteboard))
            #expect(terminalPayload.sftpItems == remote)
            #expect(terminalPayload.fileURLs.isEmpty)
            #expect(terminalPayload.preferredKind == .sftpItems)
        }

        @Test
        func finderImagePrefersItsFileURLAndFilename() throws {
            let pasteboard = stagedPasteboard()
            defer { pasteboard.releaseGlobally() }
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

        /// Hidden layers keep their receivers mounted — the Assistant panel
        /// holds the Workspace layer behind the sidebar chat list, and every
        /// Workspace stays in the deck at `opacity(0)`. AppKit consults neither
        /// when it picks a drag destination, so a disabled copy used to accept
        /// the drop and attach the file to a conversation nobody could see.
        @Test
        func disabledTargetLeavesTheDragToWhateverIsOnScreen() throws {
            let pasteboard = stagedPasteboard()
            defer { pasteboard.releaseGlobally() }

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("termind-disabled-drop-target-test.txt")
            try Data("probe".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(pasteboard.writeObjects([file as NSURL]))

            let target = FileURLDropNSView(isTargeted: { _ in }, receive: { _ in true })
            target.frame = CGRect(x: 0, y: 0, width: 200, height: 100)

            #expect(target.registeredDraggedTypes.contains(.fileURL))
            #expect(participation(target, pasteboard))
            #expect(target.supportedPayload(from: pasteboard) != nil)

            target.isEnabled = false

            #expect(target.registeredDraggedTypes.isEmpty)
            #expect(!participation(target, pasteboard))
            #expect(target.supportedPayload(from: pasteboard) == nil)

            target.isEnabled = true

            #expect(target.registeredDraggedTypes.contains(.fileURL))
            #expect(participation(target, pasteboard))
            #expect(target.supportedPayload(from: pasteboard) != nil)
        }

        /// The half no `didSet` can cover: a property assigned in `init` never
        /// runs its own observer.
        @Test
        func targetBornDisabledNeverRegistersAsADestination() {
            let target = FileURLDropNSView(
                isEnabled: false, isTargeted: { _ in }, receive: { _ in true }
            )

            #expect(target.registeredDraggedTypes.isEmpty)
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
