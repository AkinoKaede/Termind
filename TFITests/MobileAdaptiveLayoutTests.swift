import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAdaptiveLayoutTests {
    @Test func widthClassificationDefaultsToCompact() {
        #expect(MobileLayout(sizeClass: nil) == .compact)
        #expect(MobileLayout(sizeClass: .compact) == .compact)
        #expect(MobileLayout(sizeClass: .regular) == .regular)
    }

    @Test func metricsMappingUsesTheCurrentPageAndRejectsRetiredBindings() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.updateLayout(.regular)
        scene.selectedDestination = .metrics
        scene.updateLayout(.compact)
        #expect(scene.selectedDestination == .vault)
        #expect(scene.compactMetricsPresented)
        let retired = scene.compactMetricsPresentation
        scene.updateLayout(.regular)
        #expect(scene.selectedDestination == .metrics)
        scene.updateLayout(.compact)
        retired.wrappedValue = false
        #expect(scene.compactMetricsPresented)
        scene.compactMetricsPresentation.wrappedValue = false
        scene.updateLayout(.regular)
        #expect(scene.selectedDestination == .vault)
        scene.updateLayout(.compact)
        scene.compactMetricsPresented = true
        scene.openSettings()
        scene.updateLayout(.regular)
        #expect(scene.selectedDestination == .settings)
        #expect(!scene.compactMetricsPresented)
    }

    @Test func layoutChangesResetOnlyWindowNavigationAndWaitForEverySave() throws {
        let app = try MobileAppModel(inMemory: true)
        let first = MobileSceneModel(app: app)
        let second = MobileSceneModel(app: app)
        first.updateLayout(.compact)
        second.updateLayout(.regular)
        let conversation = first.assistant.conversation
        conversation.composer.draft = "Keep the existing conversation"
        first.openNewHost()
        first.updateLayout(.compact)
        #expect(first.editingHost != nil)
        let a = first.layoutTransition.beginSave()
        let b = first.layoutTransition.beginSave()
        first.updateLayout(.regular)
        #expect(first.layout == .compact)
        first.layoutTransition.endSave(a)
        first.updateLayout(.regular)
        #expect(first.editingHost != nil)
        first.layoutTransition.endSave(b)
        first.updateLayout(.regular)
        #expect(first.layout == .regular)
        #expect(first.editingHost == nil)
        #expect(first.assistant.conversation === conversation)
        #expect(conversation.composer.draft == "Keep the existing conversation")
        #expect(second.layoutRevision == 0)
        #expect(second.selectedDestination == .vault)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func realRootSwitchesBetweenNativeSidebarAndFourTabs(language: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        try await withRoot(app: app, scene: scene, language: language) { controller in
            for sizeClass: UIUserInterfaceSizeClass in [.regular, .compact, .regular, .compact] {
                resize(controller, to: sizeClass)
                try await settle()
                if sizeClass == .regular {
                    let split = try #require(find(UISplitViewController.self, in: controller))
                    #expect(find(UITabBarController.self, in: controller) == nil)
                    let sidebar = try #require(split.viewController(for: .primary))
                    let list = try #require(find(UICollectionView.self, in: sidebar.view))
                    #expect((0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) } == 5)
                    for (row, destination) in [
                        MobileDestination.vault, .metrics, .workspaces, .assistant, .settings,
                    ].enumerated() {
                        try selectRow(row, inSectionWithCount: 5, in: sidebar)
                        try await settle()
                        #expect(scene.selectedDestination == destination)
                        #expect(find(UISplitViewController.self, in: controller) === split)
                    }
                    try selectRow(0, inSectionWithCount: 5, in: sidebar)
                    try await settle()
                } else {
                    #expect(find(UISplitViewController.self, in: controller) == nil)
                    let tabs = try #require(find(UITabBarController.self, in: controller))
                    #expect(tabs.tabBar.items?.count == 4)
                    #expect(!tabs.isTabBarHidden)
                }
                capture(controller, name: "root-\(sizeClass == .regular ? "wide" : "narrow")-\(language)")
            }
        }
    }

    @Test func coldCompactRootKeepsTheConversationAndDraftAcrossReconstruction() async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .assistant
        let conversation = scene.assistant.conversation
        conversation.composer.draft = "Keep this draft through rotation"
        try await withRoot(app: app, scene: scene, initialSizeClass: .compact) { controller in
            let tabs = try #require(find(UITabBarController.self, in: controller))
            #expect(tabs.tabBar.items?.count == 4)
            #expect(tabs.selectedIndex == 2)
            for sizeClass: UIUserInterfaceSizeClass in [.regular, .compact] {
                resize(controller, to: sizeClass)
                try await settle()
                #expect(scene.selectedDestination == .assistant)
                #expect(scene.assistant.conversation === conversation)
                #expect(conversation.composer.draft == "Keep this draft through rotation")
            }
        }
    }

    @Test func metricsReopensAtTheListAndBackDoesNotRestoreItLater() async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .metrics
        try await withRoot(app: app, scene: scene) { controller in
            for sizeClass: UIUserInterfaceSizeClass in [.compact, .regular, .compact] {
                resize(controller, to: sizeClass)
                try await settle()
                #expect(scene.selectedDestination == (sizeClass == .regular ? .metrics : .vault))
                let navigation = try #require(navigation(titled: "Metrics", in: controller))
                #expect(navigation.topViewController?.navigationItem.title == "Metrics")
            }
            let metrics = try #require(navigation(titled: "Metrics", in: controller))
            metrics.popViewController(animated: false)
            try await settle()
            #expect(!scene.compactMetricsPresented)
            resize(controller, to: .regular)
            try await settle()
            #expect(scene.selectedDestination == .vault)
            #expect(navigation(titled: "Vault", in: controller) != nil)
        }
    }

    @Test func settingsDepthAndUnsavedFormsResetOnlyAcrossWidthClasses() async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.openSettings()
        try await withRoot(app: app, scene: scene) { controller in
            let settings = try #require(navigation(titled: "Settings", in: controller))
            try selectRow(3, inSectionWithCount: 5, in: settings.topViewController!)
            try await settle()
            let ai = try #require(navigation(titled: "AI", in: controller))
            try selectRow(0, inSectionWithCount: 4, in: ai.topViewController!)
            try await settle()
            let models = try #require(navigation(titled: "Models", in: controller))
            let detail = models.topViewController
            controller.view.frame.size.width = 900
            controller.view.layoutIfNeeded()
            try await settle()
            #expect(models.topViewController === detail)
            resize(controller, to: .compact)
            try await settle()
            #expect(navigation(titled: "Settings", in: controller) != nil)
            #expect(navigation(titled: "Models", in: controller) == nil)
            scene.openNewHost()
            try await settle()
            let sheet = try #require(presented(in: controller))
            let field = try #require(find(UITextField.self, in: sheet.view))
            field.text = "Discarded draft"
            field.sendActions(for: .editingChanged)
            resize(controller, to: .regular)
            try await settle()
            #expect(scene.editingHost == nil)
            #expect(presented(in: controller) == nil)
            #expect(app.library.hosts.isEmpty)
        }
    }

    @Test func twoWindowsResizeIndependentlyWhileOneSaveIsPending() async throws {
        let app = try MobileAppModel(inMemory: true)
        let first = MobileSceneModel(app: app)
        let second = MobileSceneModel(app: app)
        first.selectedDestination = .metrics
        second.openSettings()
        try await withRoot(app: app, scene: first) { firstRoot in
            try await withRoot(app: app, scene: second) { secondRoot in
                let save = first.layoutTransition.beginSave()
                resize(firstRoot, to: .compact)
                resize(secondRoot, to: .compact)
                try await settle()
                #expect(first.layout == .regular)
                #expect(second.layout == .compact)
                #expect(second.selectedDestination == .settings)
                first.layoutTransition.endSave(save)
                try await settle()
                #expect(first.layout == .compact)
                #expect(first.compactMetricsPresented)
                #expect(second.layout == .compact)
                #expect(!second.compactMetricsPresented)
            }
        }
    }

    @Test(arguments: [false, true])
    func savingInTheRealRootDefersRebuildingUntilCompletionOrErrorFeedback(fails: Bool) async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.openSettings()
        let draft = SavingDraft(fails: fails)
        var features = MobileFeatureRegistry()
        features.register(
            MobileFeatureRegistration(
                id: .settings, title: "Settings", symbol: "gearshape",
                placements: [
                    MobileFeaturePlacement(surface: .compactTab, order: 0),
                    MobileFeaturePlacement(surface: .regularSidebar, order: 0),
                ]
            ) { _, _, _ in AnyView(SavingFeature(draft: draft)) })
        defer { draft.finish() }
        try await withRoot(app: app, scene: scene, features: features) { controller in
            let sheet = try #require(presented(in: controller))
            let editor = try #require(find(UINavigationController.self, in: sheet))
            let item = try #require(editor.topViewController?.navigationItem)
            let buttons = item.trailingItemGroups.flatMap(\.barButtonItems) + (item.rightBarButtonItems ?? [])
            let save = try #require(buttons.first { ($0.accessibilityLabel ?? $0.title) == "Save" })
            let action = try #require(save.action)
            #expect(UIApplication.shared.sendAction(action, to: save.target, from: save, for: nil))
            try await settle()
            #expect(scene.layoutTransition.isBlocked)
            for sizeClass: UIUserInterfaceSizeClass in [.compact, .regular, .compact] {
                resize(controller, to: sizeClass)
                try await settle()
                #expect(scene.layout == .regular)
                #expect(presented(in: controller) === sheet)
                #expect(draft.saveCount == 1)
                capture(sheet, name: "saving-\(sizeClass == .regular ? "wide" : "narrow")")
            }
            draft.finish()
            try await settle()
            if fails {
                #expect(scene.layout == .regular)
                #expect(scene.layoutTransition.isBlocked)
                #expect(draft.isPresented)
                #expect(draft.text == "Unsaved input")
                #expect(find(UIAlertController.self, in: sheet) != nil)
            } else {
                #expect(scene.layout == .compact)
                #expect(!scene.layoutTransition.isBlocked)
                #expect(!draft.isPresented)
            }
            #expect(draft.saveCount == 1)
        }
    }

    private func selectRow(_ row: Int, inSectionWithCount count: Int, in controller: UIViewController) throws {
        let list = try #require(find(UICollectionView.self, in: controller.view))
        let section = try #require((0..<list.numberOfSections).first { list.numberOfItems(inSection: $0) == count })
        let path = IndexPath(item: row, section: section)
        list.selectItem(at: path, animated: false, scrollPosition: [])
        list.delegate?.collectionView?(list, didSelectItemAt: path)
    }

    private func presented(in controller: UIViewController) -> UIViewController? {
        if let presented = controller.presentedViewController { return presented }
        return controller.children.lazy.compactMap { presented(in: $0) }.first
    }

    private func withRoot(
        app: MobileAppModel, scene: MobileSceneModel, language: String = "en",
        features: MobileFeatureRegistry = .standard(),
        initialSizeClass: UIUserInterfaceSizeClass = .regular,
        check: (UIViewController) async throws -> Void
    ) async throws {
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = windowScene.keyWindow
        let window = UIWindow(windowScene: windowScene)
        let container = UIViewController()
        let controller = UIHostingController(
            rootView: MobileRootView(app: app, scene: scene, features: features)
                .environment(\.locale, Locale(identifier: language)))
        window.rootViewController = container
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        window.windowLevel = .alert + 3
        window.makeKeyAndVisible()
        resize(controller, to: initialSizeClass)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await settle()
        try await check(controller)
    }

    private func resize(_ controller: UIViewController, to sizeClass: UIUserInterfaceSizeClass) {
        controller.traitOverrides.horizontalSizeClass = sizeClass
        controller.view.frame = CGRect(x: 0, y: 0, width: sizeClass == .regular ? 1024 : 430, height: 800)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    private func find<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let match = controller as? T { return match }
        if let presented = controller.presentedViewController, let match = find(type, in: presented) { return match }
        return controller.children.lazy.compactMap { find(type, in: $0) }.first
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private func navigation(titled title: String, in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController,
            navigation.topViewController?.navigationItem.title == title
        {
            return navigation
        }
        return controller.children.lazy.compactMap { navigation(titled: title, in: $0) }.first
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }

    private func capture(_ controller: UIViewController, name: String) {
        let data = UIGraphicsImageRenderer(bounds: controller.view.bounds).pngData { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(data, named: "\(name).png")
    }
}

@Observable @MainActor private final class SavingDraft {
    enum Failure: Error { case expected }
    var isPresented = true
    var text = "Unsaved input"
    var saveCount = 0
    var continuation: CheckedContinuation<Void, Never>?
    let fails: Bool

    init(fails: Bool) { self.fails = fails }

    func save() async throws {
        saveCount += 1
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        if fails { throw Failure.expected }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private struct SavingFeature: View {
    @Bindable var draft: SavingDraft
    var body: some View {
        Text("Settings")
            .navigationTitle("Settings")
            .sheet(isPresented: $draft.isPresented) {
                MobileEditorSheet(title: "Snippet", isDirty: true, save: draft.save) {
                    TextField("Title", text: $draft.text)
                }
            }
    }
}
