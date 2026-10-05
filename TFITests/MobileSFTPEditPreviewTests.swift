import Foundation
import ListViewKit
import QuickLook
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileSFTPEditPreviewTests {
    private nonisolated struct InsetItem: Identifiable, Hashable {
        let id: Int
    }

    @Test(.requiresKeyWindow) func overlayClearancePreservesTheFullMobileListViewport() throws {
        let controller = UIHostingController(
            rootView:
                MobileNativeList(items: (0..<16).map { InsetItem(id: $0) }, bottomContentInset: 180) { item in
                    Text("File \(item.id)").frame(height: 48)
                }.frame(width: 400, height: 320))
        controller.safeAreaRegions = []
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        controller.view.layoutIfNeeded()
        func findList(_ view: UIView) -> ListView<InsetItem>? {
            if let list = view as? ListView<InsetItem> { return list }
            return view.subviews.lazy.compactMap(findList).first
        }
        let list = try #require(findList(controller.view))
        #expect(list.bounds.height == 320)
        #expect(list.contentInset.bottom == 180)
    }

    @Test func previewEnablesSystemEditingAndReceivesInPlaceChanges() {
        let url = URL(filePath: "/tmp/document.pdf")
        var changes = 0
        let preview = MobileSFTPEditPreview(
            url: url, allowsEditing: true, changed: { changes += 1 }, export: { _ in }, failed: { _ in }, dismiss: {})
        let delegate = preview.makeCoordinator()
        let controller = QLPreviewController()
        #expect(delegate.previewController(controller, editingModeFor: url as NSURL) == .updateContents)
        delegate.previewController(controller, didUpdateContentsOf: url as NSURL)
        #expect(changes == 1)
        delegate.parent = MobileSFTPEditPreview(
            url: url, allowsEditing: false, changed: {}, export: { _ in }, failed: { _ in }, dismiss: {})
        #expect(delegate.previewController(controller, editingModeFor: url as NSURL) == .disabled)
    }

    @Test func editedCopiesAreOwnedBeforeCallbackReturnsAndDifferentFormatsAreExported() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "original.pdf")
        let sameType = directory.appending(path: "edited.pdf")
        let differentType = directory.appending(path: "edited.png")
        try Data([1]).write(to: original)
        try Data([2]).write(to: sameType)
        try Data([3]).write(to: differentType)
        var changes = 0
        var exported: URL?
        let delegate = MobileSFTPEditPreview(
            url: original, allowsEditing: true, changed: { changes += 1 },
            export: { exported = $0 }, failed: { Issue.record("\($0)") }, dismiss: {}
        ).makeCoordinator()
        let controller = QLPreviewController()
        delegate.previewController(controller, didSaveEditedCopyOf: original as NSURL, at: sameType)
        try FileManager.default.removeItem(at: sameType)
        #expect(try Data(contentsOf: original) == Data([2]))
        #expect(changes == 1)
        delegate.previewController(controller, didSaveEditedCopyOf: original as NSURL, at: differentType)
        try FileManager.default.removeItem(at: differentType)
        #expect(try Data(contentsOf: original) == Data([2]))
        #expect(try Data(contentsOf: #require(exported)) == Data([3]))
        #expect(changes == 1)
    }

    @Test(.requiresKeyWindow) func nativeImagePreviewOffersTheSystemEditingSurface() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sftp-edit-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "preview-fixture.png")
        let fixture = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.white.setFill()
            context.fill(CGRect(x: 60, y: 60, width: 280, height: 180))
        }
        try #require(fixture.pngData()).write(to: url)
        #expect(QLPreviewController.canPreview(url as NSURL))
        let preview = MobileSFTPEditPreview(
            url: url, allowsEditing: true, changed: {}, export: { _ in },
            failed: { Issue.record("\($0)") }, dismiss: {})
        let controller = UIHostingController(rootView: preview.ignoresSafeArea())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(2))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let snapshot = directory.appending(path: "ios-native-editable-preview.png")
        try #require(image.pngData()).write(to: snapshot)
        print("SFTP native preview snapshot: \(snapshot.path)")
    }

    @Test(.requiresKeyWindow) func floatingChangesFitPhoneAndTabletWidthsAndRenderOverFileRows() async throws {
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
            for width in [320.0, 768.0] {
                for locale in ["en", "zh-Hans", "zh-Hant"] {
                    let controller = UIHostingController(
                        rootView:
                            editOverlay(files: Array(files.prefix(count)))
                            .environment(\.locale, Locale(identifier: locale))
                            .padding(12).frame(width: width))
                    controller.safeAreaRegions = []
                    let size = controller.sizeThatFits(in: CGSize(width: width, height: 2_000))
                    let visibleRows = min(count, 3)
                    let expectedHeight = 24 + 76 * Double(visibleRows) + Double(visibleRows - 1)
                    #expect(size.height >= expectedHeight && size.height < expectedHeight + 32)
                    #expect(size.width <= width)
                }
            }
        }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for count in [1, 3, 5] {
            for width in [320.0, 768.0] {
                for scheme in [ColorScheme.light, .dark] {
                    let size = CGSize(width: width, height: 500)
                    let controller = UIHostingController(
                        rootView:
                            fileRowBackdrop
                            .frame(width: size.width, height: size.height)
                            .overlay(alignment: .bottom) {
                                editOverlay(files: Array(files.prefix(count))).padding(12)
                            }
                            .environment(\.colorScheme, scheme))
                    controller.safeAreaRegions = []
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(origin: .zero, size: size)
                    window.windowLevel = .alert + 1
                    window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                    window.rootViewController = controller
                    window.makeKeyAndVisible()
                    defer {
                        window.isHidden = true
                        window.rootViewController = nil
                    }
                    controller.view.frame = CGRect(origin: .zero, size: size)
                    controller.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(700))
                    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                        _ = controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                    }
                    let directory = FileManager.default.temporaryDirectory.appending(path: "sftp-edit-screenshots")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let appearance = scheme == .dark ? "dark" : "light"
                    let url = directory.appending(path: "ios-\(Int(width))-\(count)-\(appearance).png")
                    try #require(image.pngData()).write(to: url)
                    print("SFTP edit snapshot: \(url.path)")
                }
            }
        }
    }

    private func editOverlay(files: [SFTPEditedFile]) -> some View {
        SFTPEditUploadOverlay(
            files: files, transfers: [], connected: true,
            upload: { _, _ in false }, resume: { _ in }, open: { _ in }, discard: { _ in }
        )
    }

    private var fileRowBackdrop: some View {
        VStack(spacing: 0) {
            ForEach(0..<11) { index in
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
