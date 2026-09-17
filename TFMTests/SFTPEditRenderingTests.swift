import AppKit
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@Suite(.serialized) @MainActor
struct SFTPEditRenderingTests {
    @Test func floatingChangesFitNarrowPanesAndOnlyShowThreeRows() throws {
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
        for width in [260.0, 560.0] {
            for locale in ["en", "zh-Hans", "zh-Hant"] {
                let view = NSHostingView(
                    rootView:
                        SFTPEditUploadOverlay(
                            files: model.modifiedFiles(for: hostID), transfers: [], connected: true,
                            upload: { _, _ in false }, resume: { _ in }, open: { _ in }, discard: { _ in }
                        )
                        .environment(\.locale, Locale(identifier: locale))
                        .padding(12).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
                let size = view.fittingSize
                #expect(size.height >= 252 && size.height < 285)
                #expect(size.width <= width)
                view.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(
                    contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
                let url = directory.appending(path: "mac-\(Int(width))-\(locale).png")
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
                print("SFTP edit snapshot: \(url.path)")
            }
        }
    }
}
