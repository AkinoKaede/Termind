import SwiftUI
import TermindDomain
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

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [DynamicTypeSize.large, .accessibility3])
    func fiveNativeTabsRemainAvailableAcrossWindowWidths(language: String, typeSize: DynamicTypeSize) async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        try await withRoot(app: app, scene: scene, language: language, typeSize: typeSize) { controller in
            let tabs = try #require(find(UITabBarController.self, in: controller))
            #expect(tabs.viewControllers?.count == 5)
            #expect(tabs.mode == .tabSidebar)
            for (width, sizeClass): (CGFloat, UIUserInterfaceSizeClass) in [
                (1024, .regular), (600, .regular), (375, .compact), (320, .compact), (1024, .regular),
            ] {
                resize(controller, to: sizeClass, width: width)
                tabs.sidebar.isHidden = true
                try await settle()
                #expect(find(UITabBarController.self, in: controller) === tabs)
                let pages = try #require(tabs.viewControllers)
                #expect(pages.count == 5)
                for (index, destination) in MobileDestination.allCases.enumerated() {
                    let page = try #require(pages.indices.contains(index) ? pages[index] : nil)
                    tabs.selectedViewController = page
                    tabs.delegate?.tabBarController?(tabs, didSelect: page)
                    try await settle()
                    #expect(scene.selectedDestination == destination)
                    #expect(tabs.selectedViewController === page)
                    let title = try #require(page.tabBarItem.title)
                    #expect(visibleLabels(in: tabs.view).contains { $0.text == title })
                }
                let items = try #require(tabs.tabBar.items)
                #expect(items.count == 5)
                capture(controller, name: "tabs-\(Int(width))-\(language)-\(typeSize)")
                let labels = visibleLabels(in: tabs.view)
                Attachment.record(
                    labels.map { "\($0.text ?? ""): \($0.bounds), natural \($0.intrinsicContentSize)" }
                        .joined(separator: "\n"), named: "tab-labels-\(Int(width))-\(language)-\(typeSize)")
                // The regular-width iPad bar scrolls when its titles do not fit.
                // Compact width puts all five destinations in the bottom bar.
                if sizeClass == .compact {
                    for item in items {
                        #expect(
                            labels.contains { $0.text == item.title }, "Missing visible tab: \(item.title ?? "")")
                    }
                }
            }
        }
    }

    @Test func compactLaunchKeepsTheConversationAndDraftAcrossResizing() async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .assistant
        let conversation = scene.assistant.conversation
        conversation.composer.draft = "Keep this draft through rotation"
        try await withRoot(app: app, scene: scene, initialSizeClass: .compact) { controller in
            let navigation = try #require(navigation(titled: "Assistant", in: controller))
            let detail = navigation.topViewController
            for sizeClass: UIUserInterfaceSizeClass in [.regular, .compact, .regular] {
                resize(controller, to: sizeClass)
                try await settle()
                #expect(scene.selectedDestination == .assistant)
                #expect(scene.assistant.conversation === conversation)
                #expect(conversation.composer.draft == "Keep this draft through rotation")
                #expect(navigation.topViewController === detail)
            }
        }
    }

    @Test func metricsStaysSelectedAcrossResizingAndTabRoundTrips() async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .metrics
        try await withRoot(app: app, scene: scene) { controller in
            let metrics = try #require(navigation(titled: "Metrics", in: controller))
            let page = metrics.topViewController
            for sizeClass: UIUserInterfaceSizeClass in [.compact, .regular, .compact] {
                resize(controller, to: sizeClass)
                try await settle()
                #expect(scene.selectedDestination == .metrics)
                #expect(navigation(titled: "Metrics", in: controller) === metrics)
                #expect(metrics.topViewController === page)
            }
            scene.openSettings()
            try await settle()
            scene.selectedDestination = .metrics
            try await settle()
            #expect(navigation(titled: "Metrics", in: controller) === metrics)
            #expect(metrics.topViewController === page)
        }
    }

    @Test func settingsDepthAndUnsavedFormsSurviveWidthChanges() async throws {
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
            for sizeClass: UIUserInterfaceSizeClass in [.compact, .regular, .compact] {
                resize(controller, to: sizeClass)
                try await settle()
                #expect(navigation(titled: "Models", in: controller) === models)
                #expect(models.topViewController === detail)
            }
            scene.openNewHost()
            try await settle()
            let hostID = try #require(scene.editingHost?.id)
            let sheet = try #require(presented(in: controller))
            let field = try #require(find(UITextField.self, in: sheet.view))
            field.text = "Preserved draft"
            field.sendActions(for: .editingChanged)
            for sizeClass: UIUserInterfaceSizeClass in [.regular, .compact, .regular] {
                resize(controller, to: sizeClass)
                try await settle()
                #expect(scene.editingHost?.id == hostID)
                #expect(presented(in: controller) === sheet)
                #expect(field.text == "Preserved draft")
                #expect(app.library.hosts.isEmpty)
            }
            sheet.dismiss(animated: false)
            try await settle()
            scene.openSettings()
            try await settle()
            #expect(navigation(titled: "Models", in: controller) === models)
            #expect(models.topViewController === detail)
        }
    }

    @Test func vaultSearchAndScrollSurviveResizing() async throws {
        let app = try MobileAppModel(inMemory: true)
        for index in 0..<40 {
            app.library.upsert(TermindDomain.Host(name: "Production \(index)", host: "server-\(index).example.invalid"))
        }
        let scene = MobileSceneModel(app: app)
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let nativeSizeClass = windowScene.traitCollection.horizontalSizeClass
        let nativeWidth: CGFloat = nativeSizeClass == .regular ? 1024 : 430
        try await withRoot(app: app, scene: scene, initialSizeClass: nativeSizeClass) { controller in
            let navigation = try #require(navigation(titled: "Vault", in: controller))
            let page = try #require(navigation.topViewController)
            let search = try #require(page.navigationItem.searchController)
            search.searchBar.text = "Production"
            search.searchBar.delegate?.searchBar?(search.searchBar, textDidChange: "Production")
            search.searchResultsUpdater?.updateSearchResults(for: search)
            try await settle()
            let scroll = try #require(find(UIScrollView.self, in: page.view))
            scroll.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            try await settle()
            capture(controller, name: "vault-scroll-before-resize")
            // iPhone stays in its native width class; iPad also crosses regular/compact.
            // Forcing regular width on a compact-only phone changes unsupported search-bar placement.
            for (width, sizeClass): (CGFloat, UIUserInterfaceSizeClass) in [
                (375, .compact), (nativeWidth, nativeSizeClass), (320, .compact),
            ] {
                resize(controller, to: sizeClass, width: width)
                try await settle()
                capture(controller, name: "vault-scroll-\(sizeClass.rawValue)")
                #expect(navigation.topViewController === page)
                #expect(page.navigationItem.searchController === search)
                #expect(search.searchBar.text == "Production")
                #expect(find(UIScrollView.self, in: page.view) === scroll)
                #expect(
                    scroll.contentOffset.y > 100,
                    "offset \(scroll.contentOffset), content \(scroll.contentSize), bounds \(scroll.bounds)")
            }
        }
    }

    @Test func twoWindowsKeepIndependentPagesAndDraftsDuringResizing() async throws {
        let app = try MobileAppModel(inMemory: true)
        let first = MobileSceneModel(app: app)
        let second = MobileSceneModel(app: app)
        first.selectedDestination = .metrics
        second.openNewHost()
        let hostID = second.editingHost?.id
        try await withRoot(app: app, scene: first) { firstRoot in
            let metrics = try #require(navigation(titled: "Metrics", in: firstRoot))
            try await withRoot(app: app, scene: second) { secondRoot in
                let sheet = try #require(presented(in: secondRoot))
                resize(firstRoot, to: .compact)
                try await settle()
                #expect(first.selectedDestination == .metrics)
                #expect(navigation(titled: "Metrics", in: firstRoot) === metrics)
                #expect(second.editingHost?.id == hostID)
                #expect(presented(in: secondRoot) === sheet)
                resize(secondRoot, to: .compact)
                resize(firstRoot, to: .regular)
                try await settle()
                #expect(presented(in: secondRoot) === sheet)
                #expect(first.editingHost == nil)
                #expect(second.selectedDestination == .vault)
            }
        }
    }

    @Test(arguments: [false, true])
    func savingSurvivesResizingThroughCompletionAndErrorFeedback(fails: Bool) async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.openSettings()
        let draft = SavingDraft(fails: fails)
        var features = MobileFeatureRegistry()
        features.register(
            MobileFeatureRegistration(id: .settings, title: "Settings", symbol: "gearshape") { _, _ in
                AnyView(SavingFeature(draft: draft))
            })
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
            for sizeClass: UIUserInterfaceSizeClass in [.compact, .regular, .compact] {
                resize(controller, to: sizeClass)
                try await settle()
                #expect(presented(in: controller) === sheet)
                #expect(draft.saveCount == 1)
                capture(sheet, name: "saving-\(sizeClass == .regular ? "wide" : "narrow")")
            }
            draft.finish()
            try await settle()
            if fails {
                #expect(draft.isPresented)
                #expect(draft.text == "Unsaved input")
                let alert = try #require(find(UIAlertController.self, in: sheet))
                resize(controller, to: .regular)
                try await settle()
                #expect(presented(in: controller) === sheet)
                #expect(find(UIAlertController.self, in: sheet) === alert)
                #expect(draft.text == "Unsaved input")
            } else {
                #expect(!draft.isPresented)
                for _ in 0..<20 where presented(in: controller) != nil {
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(presented(in: controller) == nil)
            }
            #expect(draft.saveCount == 1)
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func recentWorkspaceListRestoresOnlySelectedRowAndNavigates(language: String) async throws {
        let suite = "termind.recent-workspace-ui.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Production", host: "server.example.invalid")
        seed.library.upsert(host)
        _ = seed.connectionHistory.record(kind: .ssh, for: host.id)
        let descriptors = [
            MobileWorkspaceDescriptor(hostID: host.id, title: "Release Shell", kind: .ssh),
            MobileWorkspaceDescriptor(hostID: host.id, title: "Project Files", kind: .sftp),
        ]
        for sizeClass: UIUserInterfaceSizeClass in [.compact, .regular] {
            let store = MobileWorkspaceStore(defaults: defaults)
            try store.save(descriptors)
            var dependencies = MobileAppDependencies.testing()
            dependencies.container = seed.container
            dependencies.workspaceStore = store
            let app = try MobileAppModel(dependencies: dependencies)
            defer { app.closeAll() }
            let scene = MobileSceneModel(app: app)
            let historyCount = app.connectionHistory.entries().count
            scene.selectedDestination = .workspaces
            try await withRoot(app: app, scene: scene, language: language, initialSizeClass: sizeClass) { root in
                #expect(app.workspaces.isEmpty)
                #expect(scene.workspaceCount == 0)
                #expect(scene.canCloseAllWorkspaces)
                let title = language == "en" ? "Workspaces" : language == "zh-Hans" ? "工作区" : "工作區"
                let navigation = try #require(navigation(titled: title, in: root))
                let page = try #require(navigation.topViewController)
                let list = try #require(find(UICollectionView.self, in: page.view))
                #expect(list.numberOfSections == 2)  // Transfers and Recent Workspaces; history stays hidden.
                #expect((0..<list.numberOfSections).contains { list.numberOfItems(inSection: $0) == 2 })
                let width = sizeClass == .compact ? "narrow" : "wide"
                capture(root, name: "recent-workspaces-\(width)-\(language)")
                // SwiftUI Button uses its gesture action, not UICollectionView's selection delegate.
                scene.selectWorkspace(descriptors[1].id)
                try await settle()
                #expect(scene.workspaceID == descriptors[1].id)
                #expect(app.workspaces.map(\.id) == [descriptors[1].id])
                #expect(app.recentWorkspaces == [descriptors[0]])
                #expect(navigation.viewControllers.count == 2)
                capture(root, name: "recent-workspace-opened-\(width)-\(language)")
                navigation.popViewController(animated: false)
                try await settle()
                #expect(scene.workspaceID == nil)
                scene.closeAllWorkspaces()
                try await settle()
                #expect(app.recentWorkspaces.isEmpty)
                #expect(!scene.canCloseAllWorkspaces)
                #expect(app.connectionHistory.entries().count == historyCount + 1)
                #expect(MobileWorkspaceListView(app: app, scene: scene).historyRows.isEmpty == false)
            }
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
        typeSize: DynamicTypeSize = .large,
        initialSizeClass: UIUserInterfaceSizeClass = .regular,
        check: (UIViewController) async throws -> Void
    ) async throws {
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = windowScene.keyWindow
        let window = UIWindow(windowScene: windowScene)
        let container = UIViewController()
        let controller = UIHostingController(
            rootView: MobileRootView(app: app, scene: scene, features: features)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, typeSize))
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

    private func resize(_ controller: UIViewController, to sizeClass: UIUserInterfaceSizeClass, width: CGFloat? = nil) {
        let frame = CGRect(x: 0, y: 0, width: width ?? (sizeClass == .regular ? 1024 : 430), height: 800)
        controller.view.window?.frame = frame
        controller.parent?.view.frame = frame
        controller.traitOverrides.horizontalSizeClass = sizeClass
        controller.view.frame = frame
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

    private func visibleLabels(in view: UIView) -> [UILabel] {
        guard !view.isHidden, view.alpha > 0, view.bounds.width > 0, view.bounds.height > 0 else { return [] }
        return (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { visibleLabels(in: $0) }
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
