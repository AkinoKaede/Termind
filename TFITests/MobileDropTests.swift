import Foundation
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import TermindIOS

@Suite @MainActor
struct MobileDropPayloadTests {
    @Test func fileRepresentationsWithoutFileURLsAreAcceptedAndSurviveTheProviderCallback() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "provider-temporary-name")
        try Data("file bytes".utf8).write(to: source)
        let provider = fileProvider(source, type: .plainText, name: "日志.log")
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        #expect(MobileDropPayloadLoader.acceptsUpload([provider]))

        let payload = await MobileDropPayloadLoader.load([provider], kinds: [.files], fileMode: .staged)
        defer { removeStaging(payload) }
        try FileManager.default.removeItem(at: source)

        let file = try #require(payload.fileURLs.first)
        #expect(file.lastPathComponent == "日志.log")
        #expect(try Data(contentsOf: file) == Data("file bytes".utf8))
        #expect(payload.failures.isEmpty)
    }

    @Test func folderAndSameNamedFilesKeepTheirNamesAndSeparateContents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appending(path: "nested/inside.txt"))
        let first = root.appending(path: "first")
        let second = root.appending(path: "second")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let providers = [
            fileProvider(folder, type: .folder, name: "bundle"),
            fileProvider(first, type: .data, name: "same.bin"),
            fileProvider(second, type: .data, name: "same.bin"),
        ]
        #expect(MobileDropPayloadLoader.acceptsUpload(providers))

        let payload = await MobileDropPayloadLoader.load(providers, kinds: [.files], fileMode: .staged)
        defer { removeStaging(payload) }
        #expect(payload.failures.isEmpty)
        #expect(payload.fileURLs.map(\.lastPathComponent) == ["bundle", "same.bin", "same.bin"])
        #expect(Set(payload.fileURLs).count == 3)
        let stagedFolder = try #require(payload.fileURLs.first)
        #expect(try Data(contentsOf: stagedFolder.appending(path: "nested/inside.txt")) == Data("nested".utf8))
        #expect(
            try payload.fileURLs.dropFirst().map { try Data(contentsOf: $0) } == [
                Data("first".utf8), Data("second".utf8),
            ])
    }

    @Test func ordinaryTextAndWebURLsStayOutOfUploadRouting() throws {
        let text = NSItemProvider(object: "echo hello" as NSString)
        let url = NSItemProvider(object: try #require(URL(string: "https://example.com")) as NSURL)
        url.suggestedName = "A web link"
        url.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) {
            @Sendable completion in
            completion(Data("https://example.com".utf8), nil)
            return nil
        }
        #expect(!MobileDropPayloadLoader.acceptsUpload([text]))
        #expect(!MobileDropPayloadLoader.acceptsUpload([url]))
        let fileURL = NSItemProvider(object: URL(fileURLWithPath: "/tmp/report.txt") as NSURL)
        #expect(MobileDropPayloadLoader.acceptsUpload([fileURL]))
    }

    @Test func unnamedInPlaceTextFilesAreAccepted() throws {
        let provider = fileProvider(URL(fileURLWithPath: "/tmp/report.txt"), type: .plainText, name: nil, inPlace: true)
        #expect(MobileDropPayloadLoader.acceptsUpload([provider]))
    }

    @Test func aFailedRepresentationIsReportedAlongsideSuccessfulFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "good.bin")
        try Data([1, 2, 3]).write(to: source)
        let good = fileProvider(source, type: .data, name: "good.bin")
        let bad = failedFileProvider()

        let mixed = await MobileDropPayloadLoader.load([bad, good], kinds: [.files], fileMode: .staged)
        defer { removeStaging(mixed) }
        #expect(mixed.fileURLs.count == 1)
        #expect(mixed.failures.count == 1)

        let failed = await MobileDropPayloadLoader.load([bad], kinds: [.files], fileMode: .staged)
        #expect(failed.fileURLs.isEmpty)
        #expect(failed.failures.count == 1)
        #expect(failed.stagedRoot == nil)
    }

    @Test func cancelledLoadingDoesNotReturnOrRetainStagedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "slow.bin")
        try Data([1]).write(to: source)
        let provider = fileProvider(source, type: .data, name: "slow.bin", delay: 0.05)
        let task = Task { await MobileDropPayloadLoader.load([provider], kinds: [.files], fileMode: .staged) }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        let payload = await task.value
        #expect(payload.fileURLs.isEmpty)
        #expect(payload.stagedRoot == nil)
    }

    @Test func assistantImageClassificationAndReferencedFilesStayCompatible() async throws {
        let image = NSItemProvider(item: Data([1, 2, 3]) as NSData, typeIdentifier: UTType.png.identifier)
        image.suggestedName = "picture.png"
        let payload = await MobileDropPayloadLoader.load([image], kinds: [.files, .images], fileMode: .staged)
        defer { removeStaging(payload) }
        #expect(payload.images == [Data([1, 2, 3])])
        #expect(payload.fileURLs.isEmpty)
        #expect(!MobileDropPayloadLoader.accepts([image], kinds: [.files]))
        #expect(MobileDropPayloadLoader.acceptsUpload([image]))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeStaging(_ payload: MobileDropPayload) {
        if let root = payload.stagedRoot { try? FileManager.default.removeItem(at: root) }
    }
}

// Provider completion handlers can run away from MainActor, as real Files providers do.
nonisolated private func fileProvider(
    _ source: URL, type: UTType, name: String?, inPlace: Bool = false, delay: TimeInterval = 0
) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = name
    provider.registerFileRepresentation(
        forTypeIdentifier: type.identifier, fileOptions: inPlace ? .openInPlace : [], visibility: .all
    ) { completion in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            completion(source, inPlace, nil)
        }
        return nil
    }
    return provider
}

nonisolated private func failedFileProvider() -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = "missing.bin"
    provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) {
        completion in
        completion(nil, false, CocoaError(.fileReadNoSuchFile))
        return nil
    }
    return provider
}

@Suite(.serialized) @MainActor
struct MobileWorkspaceDropTests {
    @Test func failedProviderDropShowsANoticeWithoutPresentingAnAlertOrTakingFocus() async throws {
        let app = try MobileAppModel(inMemory: true)
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: UUID(), title: "Upload Test", kind: .ssh), hosts: app.library)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack {
                MobileWorkspaceView(
                    library: app.library, commandGenerator: app.commandGenerator,
                    workspace: workspace, workspaces: [workspace.descriptor], selectWorkspace: { _ in },
                    renameWorkspace: { _ in }, canCloseMultipleWorkspaces: false,
                    openSameDirectory: { _ in }, closeWorkspace: { _ in },
                    closeOtherWorkspaces: { _ in })
            }
            .environment(\.scenePhase, .active))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            workspace.disconnect()
        }
        controller.view.layoutIfNeeded()
        workspace.terminal.requestFocus()
        try await Task.sleep(for: .milliseconds(300))
        let responder = try #require(firstResponder(in: window))
        let region = try #require(dropRegion(in: controller.view))
        let interaction = try #require(window.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let delegate = try #require(interaction.delegate)
        let session = TestDropSession(providers: [failedFileProvider()], window: window)
        session.point = region.convert(CGPoint(x: region.bounds.midX, y: region.bounds.midY), to: window)
        delegate.dropInteraction?(interaction, sessionDidEnter: session)
        delegate.dropInteraction?(interaction, performDrop: session)
        delegate.dropInteraction?(interaction, sessionDidEnd: session)
        for _ in 0..<100 where workspace.uploadNotice?.isRejected != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.uploadNotice?.isRejected == true)
        #expect(workspace.operationError == nil)
        #expect(controller.presentedViewController == nil)
        #expect(firstResponder(in: window) === responder)
        try await Task.sleep(for: .milliseconds(200))
        let data = try #require(snapshot(window))
        let name = "terminal-upload-provider-\(Locale.current.identifier)"
        Attachment.record(data, named: "\(name).png")
        try data.write(to: FileManager.default.temporaryDirectory.appending(path: "\(name).png"))
        try await Task.sleep(for: .milliseconds(3000))
        #expect(workspace.uploadNotice == nil)
        #expect(firstResponder(in: window) === responder)
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        return view.subviews.lazy.compactMap { firstResponder(in: $0) }.first
    }

    @Test(arguments: ConnectionHistoryEntry.Kind.allCases)
    func hostedWorkspacesRenderTheOverlayAcrossTheirContent(kind: ConnectionHistoryEntry.Kind) async throws {
        let app = try MobileAppModel(inMemory: true)
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: UUID(), title: "Drop Test", kind: kind), hosts: app.library)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack {
                MobileWorkspaceView(
                    library: app.library, commandGenerator: app.commandGenerator,
                    workspace: workspace, workspaces: [workspace.descriptor], selectWorkspace: { _ in },
                    renameWorkspace: { _ in }, canCloseMultipleWorkspaces: false,
                    openSameDirectory: { _ in }, closeWorkspace: { _ in },
                    closeOtherWorkspaces: { _ in })
            }
            .environment(\.scenePhase, .active)
            .transaction { $0.disablesAnimations = true })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            workspace.disconnect()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let region = try #require(dropRegion(in: controller.view))
        #expect(region.bounds.width > 100)
        #expect(region.bounds.height > 100)
        let interaction = try #require(window.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let delegate = try #require(interaction.delegate)
        let session = TestDropSession(
            providers: [fileProvider(URL(fileURLWithPath: "/tmp/report.txt"), type: .plainText, name: "report.txt")],
            window: window)
        session.point = region.convert(CGPoint(x: region.bounds.midX, y: region.bounds.midY), to: window)
        #expect(delegate.dropInteraction?(interaction, canHandle: session) == true)
        let before = snapshot(window)
        delegate.dropInteraction?(interaction, sessionDidEnter: session)
        try await Task.sleep(for: .milliseconds(100))
        let during = snapshot(window)
        #expect(before != during)
        Attachment.record(try #require(during), named: "\(kind.rawValue)-drop-overlay.png")
        delegate.dropInteraction?(interaction, sessionDidEnd: session)
    }

    private func dropRegion(in view: UIView) -> MobileWindowDropTarget.InstallerView? {
        if let region = view as? MobileWindowDropTarget.InstallerView { return region }
        return view.subviews.lazy.compactMap { dropRegion(in: $0) }.first
    }

    private func snapshot(_ window: UIWindow) -> Data? {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.pngData()
    }

    @Test func windowTargetTracksOnlyTheVisibleWorkspaceAndClearsOnExitOrDisable() throws {
        let fixture = DropFixture()
        defer { fixture.close() }
        let session = fixture.fileSession()
        #expect(fixture.coordinator.dropInteraction(fixture.interaction, canHandle: session))
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidEnter: session)
        #expect(fixture.targeted)
        #expect(fixture.coordinator.dropInteraction(fixture.interaction, sessionDidUpdate: session).operation == .copy)
        // Crossing into the sidebar stays in the window but leaves the workspace.
        session.point = CGPoint(x: 40, y: 200)
        #expect(
            fixture.coordinator.dropInteraction(fixture.interaction, sessionDidUpdate: session).operation == .cancel)
        #expect(!fixture.targeted)
        fixture.coordinator.dropInteraction(fixture.interaction, performDrop: session)
        #expect(fixture.received == 0)
        session.point = CGPoint(x: 400, y: 200)
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidEnter: session)
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidExit: session)
        #expect(!fixture.targeted)
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidEnter: session)
        fixture.coordinator.isEnabled = false
        #expect(!fixture.targeted)
        #expect(!fixture.coordinator.dropInteraction(fixture.interaction, canHandle: session))
    }

    @Test func terminalRoutingUploadsOnceAndPreservesTextAndLinkHandling() throws {
        let fixture = DropFixture()
        defer { fixture.close() }
        let terminal = UIView(frame: fixture.region.bounds)
        fixture.region.addSubview(terminal)
        let originalDelegate = RecordingDropDelegate()
        let originalInteraction = UIDropInteraction(delegate: originalDelegate)
        terminal.addInteraction(originalInteraction)
        fixture.coordinator.install(in: fixture.region, terminalView: terminal)
        let interaction = try #require(terminal.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let delegate = try #require(interaction.delegate)
        #expect(interaction !== originalInteraction)
        let session = fixture.fileSession()
        #expect(delegate.dropInteraction?(interaction, canHandle: session) == true)
        delegate.dropInteraction?(interaction, sessionDidEnter: session)
        #expect(fixture.targeted)
        // A late exit from the window must not clear the terminal's targeting.
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidExit: session)
        #expect(fixture.targeted)
        delegate.dropInteraction?(interaction, performDrop: session)
        fixture.coordinator.dropInteraction(fixture.interaction, performDrop: session)
        #expect(fixture.received == 1)
        #expect(!fixture.targeted)
        #expect(originalDelegate.drops == 0)
        for provider in [
            NSItemProvider(object: "echo hi" as NSString),
            NSItemProvider(object: try #require(URL(string: "https://example.com")) as NSURL),
        ] {
            let textSession = TestDropSession(providers: [provider], window: fixture.window)
            #expect(delegate.dropInteraction?(interaction, canHandle: textSession) == true)
            let proposal = delegate.dropInteraction?(interaction, sessionDidUpdate: textSession)
            #expect(proposal?.operation == .copy)
            delegate.dropInteraction?(interaction, performDrop: textSession)
        }
        #expect(originalDelegate.drops == 2)
        #expect(fixture.received == 1)
        fixture.coordinator.uninstall()
        #expect(terminal.interactions.contains { $0 === originalInteraction })
    }

    @Test func pinnedGhosttyInteractionIsReplacedAndRestored() throws {
        let fixture = DropFixture()
        defer { fixture.close() }
        let terminal = MobileTerminalView(frame: .zero)
        let original = try #require(terminal.interactions.compactMap { $0 as? UIDropInteraction }.first)
        #expect(original.delegate === terminal)
        fixture.coordinator.install(in: fixture.region, terminalView: terminal)
        #expect(!terminal.interactions.contains { $0 === original })
        fixture.coordinator.uninstall()
        #expect(terminal.interactions.contains { $0 === original })
    }

    @Test func reattachingATerminalBeforeOldDestinationTeardownPreservesTheOriginalDelegate() throws {
        let terminal = MobileTerminalView(frame: .zero)
        let original = try #require(terminal.interactions.compactMap { $0 as? UIDropInteraction }.first)
        let firstDelegate = RecordingDropDelegate()
        let secondDelegate = RecordingDropDelegate()
        let first = try #require(MobileTerminalDropTarget(view: terminal, uploadDelegate: firstDelegate))
        let second = try #require(MobileTerminalDropTarget(view: terminal, uploadDelegate: secondDelegate))
        first.uninstall()
        #expect(!terminal.interactions.contains { $0 === original })
        second.uninstall()
        #expect(terminal.interactions.contains { $0 === original })
        #expect(original.delegate === terminal)
    }

    @Test func hidingPresentingOrDetachingTheWorkspaceRejectsDrops() async throws {
        let fixture = DropFixture()
        defer { fixture.close() }
        let session = fixture.fileSession()
        fixture.region.isHidden = true
        #expect(!fixture.coordinator.dropInteraction(fixture.interaction, canHandle: session))
        fixture.region.isHidden = false
        fixture.window.rootViewController?.present(UIViewController(), animated: false)
        #expect(fixture.window.rootViewController?.presentedViewController != nil)
        #expect(
            fixture.coordinator.dropInteraction(fixture.interaction, sessionDidUpdate: session).operation == .cancel)
        fixture.coordinator.dropInteraction(fixture.interaction, performDrop: session)
        #expect(fixture.received == 0)
        fixture.window.rootViewController?.dismiss(animated: false)
        fixture.region.removeFromSuperview()
        #expect(!fixture.coordinator.dropInteraction(fixture.interaction, canHandle: session))
    }

    @Test func movingBetweenWindowsRemovesTheOldInteractionAndClearsTargeting() throws {
        let fixture = DropFixture()
        let other = DropFixture()
        defer {
            fixture.close()
            other.close()
        }
        let session = fixture.fileSession()
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidEnter: session)
        #expect(fixture.targeted)
        other.window.rootViewController?.view.addSubview(fixture.region)
        fixture.coordinator.moveToWindow()
        #expect(!fixture.targeted)
        #expect(!fixture.window.interactions.contains { $0 === fixture.interaction })
        #expect(other.window.interactions.contains { $0 === fixture.interaction })
        fixture.coordinator.uninstall()
        #expect(other.window.interactions.contains { $0 === other.interaction })
    }

    @Test func endingOrUninstallingADragClearsTheOverlay() {
        let fixture = DropFixture()
        defer { fixture.close() }
        let session = fixture.fileSession()
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidEnter: session)
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidEnd: session)
        #expect(!fixture.targeted)
        fixture.coordinator.dropInteraction(fixture.interaction, sessionDidEnter: session)
        fixture.coordinator.uninstall()
        #expect(!fixture.targeted)
        #expect(!fixture.window.interactions.contains { $0 === fixture.interaction })
    }
}

@MainActor
private final class DropFixture {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
    let region = UIView(frame: CGRect(x: 300, y: 100, width: 724, height: 668))
    var targeted = false
    var received = 0
    lazy var coordinator = MobileWindowDropTarget.Coordinator(
        isEnabled: true,
        targeted: { [weak self] in self?.targeted = $0 },
        receive: { [weak self] _ in
            self?.received += 1
            return true
        }
    )
    var interaction: UIDropInteraction!

    init() {
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(region)
        window.isHidden = false
        coordinator.install(in: region)
        interaction = window.interactions.compactMap { $0 as? UIDropInteraction }.first
    }

    func fileSession() -> TestDropSession {
        TestDropSession(
            providers: [fileProvider(URL(fileURLWithPath: "/tmp/report.txt"), type: .plainText, name: "report.txt")],
            window: window)
    }

    func close() {
        coordinator.uninstall()
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private final class RecordingDropDelegate: NSObject, UIDropInteractionDelegate {
    var drops = 0
    func dropInteraction(_: UIDropInteraction, canHandle _: any UIDropSession) -> Bool { true }
    func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }
    func dropInteraction(_: UIDropInteraction, performDrop _: any UIDropSession) { drops += 1 }
}

@MainActor
private final class TestDropSession: NSObject, UIDropSession {
    let items: [UIDragItem]
    weak var window: UIWindow?
    var point = CGPoint(x: 400, y: 200)
    let allowsMoveOperation = false
    let isRestrictedToDraggingApplication = false
    let localDragSession: (any UIDragSession)? = nil
    nonisolated let progress = Progress(totalUnitCount: 0)
    var progressIndicatorStyle = UIDropSessionProgressIndicatorStyle.none

    init(providers: [NSItemProvider], window: UIWindow) {
        items = providers.map(UIDragItem.init(itemProvider:))
        self.window = window
    }

    func location(in view: UIView) -> CGPoint { view.convert(point, from: window) }
    func hasItemsConforming(toTypeIdentifiers identifiers: [String]) -> Bool {
        items.contains { item in identifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) } }
    }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
        items.contains { $0.itemProvider.canLoadObject(ofClass: aClass) }
    }
    func loadObjects(
        ofClass aClass: any NSItemProviderReading.Type,
        completion: @escaping ([any NSItemProviderReading]) -> Void
    ) -> Progress {
        completion([])
        return progress
    }
}
