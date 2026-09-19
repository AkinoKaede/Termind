import AppKit
import Foundation
import ListViewKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct SFTPEditRenderingTests {
    @Test(.requiresVisibleWindow) func menuHoverInspection() async throws {
        let model = SFTPEditModel()
        let hostID = UUID()
        let file = RemoteFile(
            path: "/test/config.json", name: "config.json", kind: .file,
            size: 1, permissions: 0o644, ownerUID: 0, ownerGID: 0)
        let id = model.register(hostID: hostID, file: file, localURL: URL(filePath: "/tmp/config.json"), digest: "a")
        model.update(id) { $0.currentDigest = "b" }
        let view = NSHostingView(
            rootView:
                fileList(inset: 112)
                .overlay(alignment: .bottom) {
                    SFTPEditUploadOverlay(
                        files: model.files, transfers: [], connected: true, upload: { _, _ in false },
                        resume: { _ in }, open: { _ in }, discard: { _ in }, keepLocalCopy: { _ in }
                    )
                    .padding(16)
                }
                .environment(\.locale, Locale(identifier: "en"))
                .frame(width: 600, height: 420).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: CGRect(x: 300, y: 300, width: 600, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SFTP Menu QA"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        print("SFTP_MENU_QA_READY")
        try await Task.sleep(for: .seconds(45))
    }

    @Test func overlayClearanceExtendsScrollContentWithoutShrinkingTheViewport() throws {
        let view = NSHostingView(rootView: fileList(inset: 180).frame(width: 400, height: 320))
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        view.layoutSubtreeIfNeeded()
        func findList(_ view: NSView) -> ListView<SFTPFileListItem>? {
            if let list = view as? ListView<SFTPFileListItem> { return list }
            return view.subviews.lazy.compactMap(findList).first
        }
        let list = try #require(findList(view))
        #expect(list.bounds.height == 320)
        #expect(list.contentInsets.bottom == 180)
        #expect(list.maximumContentOffset.y >= 180)
    }

    private func fileList(inset: CGFloat) -> SFTPFileNativeList {
        let items = (0..<16).map { index in
            let file = RemoteFile(
                path: "/srv/logs/server-\(index).log", name: "server-\(index).log", kind: .file,
                size: 4096, permissions: 0o644, ownerUID: 0, ownerGID: 0)
            return SFTPFileListItem(
                row: SFTPRow(file: file), parentPath: nil, isSelected: false,
                isEmphasized: false, isHovered: false, layoutKey: 0)
        }
        return SFTPFileNativeList(
            items: items, scrollRequest: nil, bottomContentInset: inset, onBackgroundClick: {},
            renderer: { item in
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(.teal)
                    Text(item.row?.file.name ?? "")
                    Spacer()
                    Text("4 KB").foregroundStyle(.secondary)
                }.padding(.horizontal, 20).frame(height: 48)
            })
    }

    @Test(.requiresVisibleWindow) func floatingChangesFitNarrowPanesAndRenderOverFileRows() throws {
        let model = SFTPEditModel()
        let hostID = UUID()
        for index in 0..<5 {
            let file = RemoteFile(
                path: "/srv/config/production-\(index).json", name: "production-\(index).json", kind: .file,
                size: 100, permissions: 0o644, ownerUID: 0, ownerGID: 0)
            let id = model.register(
                hostID: hostID, file: file, localURL: URL(filePath: "/tmp/\(file.name)"), digest: "one")
            model.update(id) { $0.currentDigest = "two" }
        }
        let files = model.modifiedFiles(for: hostID)
        for count in [1, 3, 5] {
            for width in [260.0, 560.0] {
                for locale in ["en", "zh-Hans", "zh-Hant"] {
                    let view = NSHostingView(
                        rootView:
                            editOverlay(files: Array(files.prefix(count)))
                            .environment(\.locale, Locale(identifier: locale))
                            .padding(12).frame(width: width))
                    let size = view.fittingSize
                    let visibleRows = min(count, 3)
                    let expectedHeight = 24 + 76 * Double(visibleRows) + Double(visibleRows - 1)
                    #expect(size.height >= expectedHeight && size.height < expectedHeight + 32)
                    #expect(size.width <= width)
                }
            }
        }

        for count in [1, 3, 5] {
            for width in [260.0, 560.0] {
                for scheme in [ColorScheme.light, .dark] {
                    let height = 420.0
                    let view = NSHostingView(
                        rootView:
                            fileRowBackdrop
                            .frame(width: width, height: height)
                            .overlay(alignment: .bottom) {
                                editOverlay(files: Array(files.prefix(count))).padding(12)
                            }
                            .environment(\.colorScheme, scheme))
                    view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    let window = NSWindow(
                        contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.contentView = view
                    window.orderFront(nil)
                    defer {
                        window.orderOut(nil)
                        window.contentView = nil
                    }
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let directory = FileManager.default.temporaryDirectory.appending(path: "sftp-edit-screenshots")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let appearance = scheme == .dark ? "dark" : "light"
                    let url = directory.appending(path: "mac-\(Int(width))-\(count)-\(appearance).png")
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
                    print("SFTP edit snapshot: \(url.path)")
                }
            }
        }
    }

    private func editOverlay(files: [SFTPEditedFile]) -> some View {
        SFTPEditUploadOverlay(
            files: files, transfers: [], connected: true,
            upload: { _, _ in false }, resume: { _ in }, open: { _ in }, discard: { _ in },
            keepLocalCopy: { _ in }
        )
    }

    private var fileRowBackdrop: some View {
        VStack(spacing: 0) {
            ForEach(0..<10) { index in
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.fill").foregroundStyle(index.isMultiple(of: 2) ? .teal : .indigo)
                    Text("server-\(index).log")
                    Spacer()
                    Text("4 KB").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(index.isMultiple(of: 2) ? Color.teal.opacity(0.10) : Color.indigo.opacity(0.10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
    }
}
