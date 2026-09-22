import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAdaptiveLayoutTests {
    @Test func metricsRetainsItsNativeListAndScrollPositionAcrossFoldsAndVerticalMenuChanges() async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .metrics
        let server = ServerMetric(selection: MetricsSelection(id: UUID(), enabled: false), name: "Fold Metrics")
        server.processes = (1...100).map {
            MetricsProcess(pid: $0, started: 1, name: "process-\($0)", cpu: Double($0), memory: Double(101 - $0))
        }
        let regions = MobileRegionTestState()
        var features = MobileFeatureRegistry()
        features.register(
            MobileFeatureRegistration(id: .metrics, title: "Metrics", symbol: "waveform.path.ecg") { app, _ in
                AnyView(
                    MobileRegionTestHost(state: regions) {
                        MobileMetricsDetailView(app: app, server: server)
                            .environment(\.mobileToolbarLayout, regions.toolbarLayout)
                    })
            })
        try await withRoot(app: app, scene: scene, features: features, initialSizeClass: .compact) { controller in
            let navigation = try #require(navigation(titled: server.name, in: controller))
            let picker = try #require(find(UISegmentedControl.self, in: controller.view))
            picker.selectedSegmentIndex = 1
            picker.sendActions(for: .valueChanged)
            try await settle()
            let list = try #require(find(UICollectionView.self, in: navigation.view))
            list.setContentOffset(CGPoint(x: 0, y: 350), animated: false)
            try await settle()
            for region in [
                MobileReservedRegion(kind: .division, frame: CGRect(x: 0, y: 280, width: 2000, height: 24)),
                MobileReservedRegion(kind: .division, frame: CGRect(x: 200, y: 0, width: 24, height: 2000)),
                MobileReservedRegion(kind: .division, frame: .zero, isActive: false),
            ] {
                regions.regions = [region]
                try await settle()
                #expect(find(UICollectionView.self, in: navigation.view) === list)
                #expect(list.contentOffset.y > 200)
                if region.isActive { #expect(find(UISegmentedControl.self, in: controller.view) == nil) }
            }
            regions.toolbarLayout.verticalEdge = .trailing
            try await settle()
            #expect(find(UISegmentedControl.self, in: controller.view) == nil)
            let menuButton = try #require(toolbarButton(namedOneOf: ["Details"], in: navigation))
            var actions = try await resolvedMenuActions(#require(menuButton.menu), in: navigation.view)
            #expect(actions.contains { $0.title == "Processes" && $0.state == .on && $0.image != nil })
            let status = try #require(actions.first { $0.title == "Status" })
            UIButton(primaryAction: status).sendActions(for: .primaryActionTriggered)
            try await settle()
            #expect(find(UICollectionView.self, in: navigation.view) === list)
            let updatedButton = try #require(toolbarButton(namedOneOf: ["Details"], in: navigation))
            actions = try await resolvedMenuActions(#require(updatedButton.menu), in: navigation.view)
            #expect(actions.contains { $0.title == "Status" && $0.state == .on })
            let processes = try #require(actions.first { $0.title == "Processes" })
            UIButton(primaryAction: processes).sendActions(for: .primaryActionTriggered)
            try await settle()
            #expect(find(UICollectionView.self, in: navigation.view) === list)
            #expect(list.contentOffset.y > 200)
            regions.toolbarLayout.verticalEdge = nil
            try await settle()
            #expect(try #require(find(UISegmentedControl.self, in: controller.view)).selectedSegmentIndex == 1)
            #expect(toolbarButton(namedOneOf: ["Details"], in: navigation) == nil)
            #expect(find(UICollectionView.self, in: navigation.view) === list)
            #expect(list.contentOffset.y > 200)
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func foldingKeepsAssistantTranscriptComposerFocusAndMarkedText(language: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .assistant
        await scene.assistant.load()
        let conversation = scene.assistant.conversation
        conversation.appendUserTurn("Keep this transcript while folding")
        conversation.composer.draft = "Draft across folds"
        let regions = MobileRegionTestState()
        try await withRoot(app: app, scene: scene, language: language, regions: regions) { controller in
            let composer = try #require(textInput(containing: conversation.composer.draft, in: controller.view))
            let input = try #require(composer as? any UITextInput)
            let transcript = try #require(find(UICollectionView.self, in: controller.view))
            #expect(composer.becomeFirstResponder())
            input.setMarkedText("输入中", selectedRange: NSRange(location: 3, length: 0))
            try await settle()
            for (index, region) in [
                MobileReservedRegion(kind: .division, frame: CGRect(x: 0, y: 160, width: 2000, height: 24)),
                MobileReservedRegion(kind: .division, frame: CGRect(x: 350, y: 0, width: 24, height: 2000)),
                MobileReservedRegion(kind: .occlusion, frame: CGRect(x: 0, y: 0, width: 40, height: 40)),
                MobileReservedRegion(kind: .division, frame: .zero, isActive: false),
            ].enumerated() {
                regions.regions = [region]
                try await settle()
                #expect(scene.assistant.conversation === conversation)
                #expect(find(UICollectionView.self, in: controller.view) === transcript)
                #expect(composer.isFirstResponder)
                #expect(composer.window != nil)
                let marked = try #require(input.markedTextRange)
                #expect(input.text(in: marked) == "输入中")
                capture(controller, name: "assistant-fold-\(index)-\(language)")
            }
            input.unmarkText()
            composer.resignFirstResponder()
        }
    }

    private func textInput(containing text: String, in view: UIView) -> UIView? {
        if let input = view as? any UITextInput,
            let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument),
            input.text(in: range) == text
        {
            return view
        }
        return view.subviews.lazy.compactMap { textInput(containing: text, in: $0) }.first
    }

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
            #expect(tabs.tabs.count == 5)
            #expect(tabs.mode == .tabSidebar)
            for (width, sizeClass): (CGFloat, UIUserInterfaceSizeClass) in [
                (1024, .regular), (600, .regular), (375, .compact), (320, .compact), (1024, .regular),
            ] {
                resize(controller, to: sizeClass, width: width)
                tabs.sidebar.isHidden = true
                try await settle()
                #expect(find(UITabBarController.self, in: controller) === tabs)
                let pages = tabs.tabs
                #expect(pages.count == 5)
                for (index, destination) in MobileDestination.allCases.enumerated() {
                    let page = try #require(pages.indices.contains(index) ? pages[index] : nil)
                    let previous = tabs.selectedTab
                    tabs.selectedTab = page
                    tabs.delegate?.tabBarController?(tabs, didSelectTab: page, previousTab: previous)
                    try await settle()
                    #expect(scene.selectedDestination == destination)
                    #expect(tabs.selectedTab === page)
                    let title = page.title
                    #expect(visibleLabels(in: tabs.view).contains { $0.text == title })
                }
                let items = tabs.tabs
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
                            labels.contains { $0.text == item.title }, "Missing visible tab: \(item.title)")
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

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func assistantSwitchersReflectAvailableConversationsAcrossToolbarLayouts(language: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .assistant
        await scene.assistant.load()
        let conversation = scene.assistant.conversation
        conversation.composer.draft = "Keep the draft while switchers update"
        let regions = MobileRegionTestState()
        var features = MobileFeatureRegistry()
        features.register(
            MobileFeatureRegistration(id: .assistant, title: "Assistant", symbol: "sparkles") { app, scene in
                AnyView(
                    MobileAssistantView(
                        app: app, model: scene.assistant,
                        libraryRoute: Binding(
                            get: { scene.assistantLibraryRoute }, set: { scene.assistantLibraryRoute = $0 })
                    )
                    .environment(\.mobileToolbarLayout, regions.toolbarLayout))
            })
        try await withRoot(app: app, scene: scene, language: language, features: features, initialSizeClass: .compact) {
            controller in
            let navigation = try #require(navigation(titled: "Assistant", in: controller))
            let page = try #require(navigation.topViewController)
            for (state, enabled) in [
                ("empty", false), ("current", true), ("pinned", true), ("archived", false), ("restored", true),
            ] {
                switch state {
                case "current":
                    conversation.appendUserTurn("The only conversation")
                    scene.assistant.library.insertAndSelect(conversation)
                case "pinned": conversation.isPinned = true
                case "archived":
                    conversation.isPinned = false
                    conversation.archivedAt = .now
                case "restored": conversation.archivedAt = nil
                default: break
                }
                // Check a data-only update before changing toolbar placement.
                try await settle()
                try expectAssistantSwitcher(in: navigation, layout: regions.toolbarLayout, enabled: enabled)
                for (name, layout) in [
                    ("title", MobileToolbarLayout()),
                    ("top", MobileToolbarLayout(isTopBar: true)),
                    ("vertical", MobileToolbarLayout(verticalEdge: .trailing)),
                ] {
                    regions.toolbarLayout = layout
                    try await settle()
                    try expectAssistantSwitcher(in: navigation, layout: layout, enabled: enabled)
                    #expect(navigation.topViewController === page)
                    #expect(scene.assistant.conversation === conversation)
                    #expect(conversation.composer.draft == "Keep the draft while switchers update")
                    let newConversation = try #require(
                        toolbarButton(namedOneOf: ["New Conversation", "新建对话", "新增對話"], in: navigation))
                    #expect(newConversation.isEnabled)
                    capture(controller, name: "assistant-switcher-\(state)-\(name)-\(language)")
                }
                if !enabled {
                    let menu: UIMenu
                    if #available(iOS 27.0, *) {
                        menu = UIMenu(children: [try #require(page.navigationItem.additionalOverflowItems)])
                    } else {
                        menu = try #require(toolbarButton(namedOneOf: ["More", "更多"], in: navigation)?.menu)
                    }
                    let actions = try await resolvedMenuActions(menu, in: page.view)
                    for names: Set<String> in [["Conversations", "对话", "對話"], ["Archived", "已归档", "已封存"]] {
                        let action = try #require(actions.first { names.contains($0.title) })
                        #expect(!action.attributes.contains(.disabled))
                    }
                }
            }
        }
    }

    private func expectAssistantSwitcher(
        in navigation: UINavigationController, layout: MobileToolbarLayout, enabled: Bool
    ) throws {
        let page = try #require(navigation.topViewController)
        let switcher = toolbarButton(namedOneOf: ["Conversations", "对话", "對話"], in: navigation)
        if layout.usesIconSwitcher {
            #expect(try #require(switcher).isEnabled == enabled)
        } else {
            #expect(switcher == nil)
            #expect((page.navigationItem.titleMenuProvider != nil) == enabled)
            #expect(visibleLabels(in: navigation.navigationBar).contains { $0.text == page.navigationItem.title })
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func assistantTitleAdaptsWithoutLosingItsConversationMenuOrDrafts(language: String) async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .assistant
        await scene.assistant.load()
        let first = ConversationModel()
        first.appendUserTurn("Investigate the production database latency")
        first.customTitle = language == "en" ? "Investigate the production database latency" : "排查生产数据库延迟与连接问题"
        first.isPinned = true
        first.composer.draft = "Keep the first draft"
        let second = ConversationModel()
        second.appendUserTurn("Review the deployment")
        second.composer.draft = "Keep the second draft"
        scene.assistant.library.insertAndSelect(second)
        scene.assistant.library.insertAndSelect(first)
        try await withRoot(app: app, scene: scene, language: language) { controller in
            let tabs = try #require(find(UITabBarController.self, in: controller))
            let navigation = try #require(navigation(titled: first.derivedTitle, in: controller))
            let page = try #require(navigation.topViewController)
            for (sizeClass, sidebar): (UIUserInterfaceSizeClass, Bool) in [
                (.regular, false), (.regular, true), (.compact, false), (.regular, false),
            ] {
                resize(controller, to: sizeClass, width: sizeClass == .regular ? 1366 : 430)
                tabs.sidebar.isHidden = !sidebar
                try await settle()
                let topBar = sizeClass == .regular && !sidebar
                capture(controller, name: "assistant-title-\(sizeClass.rawValue)-\(sidebar)-\(language)")
                #expect(navigation.topViewController === page)
                #expect(scene.assistant.conversation === first)
                #expect(first.composer.draft == "Keep the first draft")
                #expect(
                    visibleLabels(in: navigation.navigationBar).contains { $0.text == first.derivedTitle } == !topBar)
                let switcher = toolbarButton(namedOneOf: ["Conversations", "对话", "對話"], in: navigation)
                #expect((switcher != nil) == topBar)
                if let switcher {
                    let trailingButtons =
                        page.navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                        + (page.navigationItem.rightBarButtonItems ?? [])
                    // System overflow is owned by UINavigationItem rather than a second custom bar button.
                    let expectedButtons = if #available(iOS 27.0, *) { 1 } else { 2 }
                    #expect(Set(trailingButtons.map(ObjectIdentifier.init)).count == expectedButtons)
                    if #available(iOS 27.0, *) { #expect(page.navigationItem.additionalOverflowItems != nil) }
                    let menu = try #require(switcher.menu)
                    let actions = try await resolvedMenuActions(menu, in: page.view)
                    #expect(actions.map(\.title).contains(first.derivedTitle))
                    let selectSecond = try #require(actions.first { $0.title == second.derivedTitle })
                    UIButton(primaryAction: selectSecond).sendActions(for: .primaryActionTriggered)
                    try await settle()
                    #expect(scene.assistant.conversation === second)
                    #expect(second.composer.draft == "Keep the second draft")
                    let updatedSwitcher = try #require(
                        toolbarButton(namedOneOf: ["Conversations", "对话", "對話"], in: navigation))
                    let updatedMenu = try #require(updatedSwitcher.menu)
                    let updatedActions = try await resolvedMenuActions(updatedMenu, in: page.view)
                    let selectFirst = try #require(updatedActions.first { $0.title == first.derivedTitle })
                    UIButton(primaryAction: selectFirst).sendActions(for: .primaryActionTriggered)
                    try await settle()
                    #expect(scene.assistant.conversation === first)
                }
            }
            for route in [MobileAssistantLibraryRoute.conversations, .archived] {
                scene.assistantLibraryRoute = route
                try await settle()
                let title = try #require(navigation.topViewController?.navigationItem.title)
                #expect(!title.isEmpty && title != first.derivedTitle)
                #expect(visibleLabels(in: navigation.navigationBar).contains { $0.text == title })
                capture(controller, name: "assistant-library-\(route.rawValue)-\(language)")
                scene.assistantLibraryRoute = nil
                try await settle()
                #expect(navigation.topViewController === page)
                #expect(!visibleLabels(in: navigation.navigationBar).contains { $0.text == first.derivedTitle })
            }
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func metricsDetailTitleAdaptsWhileItsPickerAndNavigationSurvive(language: String) async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app)
        scene.selectedDestination = .metrics
        let server = ServerMetric(
            selection: MetricsSelection(id: UUID(), enabled: false),
            name: language == "en" ? "Production database server in Singapore" : "新加坡生产环境数据库服务器")
        var features = MobileFeatureRegistry()
        for feature in MobileFeatureRegistry.standard().registrations {
            features.register(
                feature.id == .metrics
                    ? MobileFeatureRegistration(id: .metrics, title: "Metrics", symbol: "waveform.path.ecg") { app, _ in
                        AnyView(MetricsDetailFeature(app: app, server: server))
                    } : feature)
        }
        try await withRoot(app: app, scene: scene, language: language, features: features) { controller in
            let tabs = try #require(find(UITabBarController.self, in: controller))
            let navigation = try #require(navigation(titled: server.name, in: controller))
            let page = try #require(navigation.topViewController)
            var selectedProcesses = false
            for (sizeClass, width, sidebar): (UIUserInterfaceSizeClass, CGFloat, Bool) in [
                (.regular, 1024, false), (.regular, 600, false), (.regular, 1366, true),
                (.compact, 430, false), (.regular, 1024, false), (.compact, 430, false),
            ] {
                resize(controller, to: sizeClass, width: width)
                tabs.sidebar.isHidden = !sidebar
                try await settle()
                capture(controller, name: "metrics-title-\(Int(width))-\(sidebar)-\(language)")
                #expect(navigation.topViewController === page)
                #expect(navigation.viewControllers.count == 2)
                #expect(page.navigationItem.title == server.name)
                if #available(iOS 27.0, *) {
                    #expect(page.navigationItem.additionalOverflowItems != nil)
                    #expect(page.navigationItem.overflowPresentationSource != nil)
                } else {
                    #expect(toolbarButton(namedOneOf: ["Metrics", "监控", "監控"], in: navigation) != nil)
                }
                if sidebar {
                    #expect(visibleLabels(in: navigation.navigationBar).contains { $0.text == server.name })
                } else if sizeClass == .regular {
                    #expect(!visibleLabels(in: navigation.navigationBar).contains { $0.text == server.name })
                }
                // The bottom bar leaves the principal toolbar slot available for the existing picker.
                if sizeClass == .compact {
                    let picker = try #require(find(UISegmentedControl.self, in: controller.view))
                    #expect(picker.numberOfSegments == 2)
                    #expect(picker.selectedSegmentIndex == (selectedProcesses ? 1 : 0))
                    picker.selectedSegmentIndex = 1
                    picker.sendActions(for: .valueChanged)
                    selectedProcesses = true
                    try await settle()
                    #expect(find(UICollectionView.self, in: page.view) != nil)
                }
            }
            navigation.popViewController(animated: false)
            try await settle()
            #expect(navigation.viewControllers.count == 1)
            #expect(scene.selectedDestination == .metrics)
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
                #expect(list.numberOfSections == 2)  // Transfers and the unified Workspaces section.
                #expect((0..<list.numberOfSections).contains { list.numberOfItems(inSection: $0) == 2 })
                #expect(app.orderedWorkspaceItems.map(\.id) == descriptors.map(\.id))
                let width = sizeClass == .compact ? "narrow" : "wide"
                capture(root, name: "recent-workspaces-\(width)-\(language)")
                // SwiftUI Button uses its gesture action, not UICollectionView's selection delegate.
                scene.selectWorkspace(descriptors[1].id)
                try await settle()
                #expect(scene.workspaceID == descriptors[1].id)
                #expect(app.workspaces.map(\.id) == [descriptors[1].id])
                #expect(app.recentWorkspaces == [descriptors[0]])
                #expect(app.orderedWorkspaceItems.map(\.id) == descriptors.map(\.id))
                #expect(list.numberOfSections == 2)
                #expect((0..<list.numberOfSections).contains { list.numberOfItems(inSection: $0) == 2 })
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
        regions: MobileRegionTestState? = nil,
        check: (UIViewController) async throws -> Void
    ) async throws {
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = windowScene.keyWindow
        let window = UIWindow(windowScene: windowScene)
        let container = UIViewController()
        let controller = UIHostingController(
            rootView: MobileRegionTestHost(state: regions) {
                MobileRootView(app: app, scene: scene, features: features)
            }
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

    private func toolbarButton(namedOneOf names: Set<String>, in navigation: UINavigationController) -> UIBarButtonItem?
    {
        guard let item = navigation.topViewController?.navigationItem else { return nil }
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems)
            + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
        return buttons.first { button in
            (button.accessibilityLabel ?? button.title ?? button.customView?.accessibilityLabel).map(names.contains)
                == true
        }
    }

    private func menuActions(_ menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return menuActions(submenu) }
            return []
        }
    }

    private func resolvedMenuActions(_ menu: UIMenu, in view: UIView) async throws -> [UIAction] {
        // SwiftUI supplies deferred menu elements. Present the native menu to ask UIKit to resolve them.
        let button = UIButton(frame: CGRect(x: 20, y: 100, width: 44, height: 44))
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        view.addSubview(button)
        defer { button.removeFromSuperview() }
        button.performPrimaryAction()
        try await settle()
        let interaction = try #require(button.contextMenuInteraction)
        var actions: [UIAction] = []
        interaction.updateVisibleMenu { resolved in
            actions = menuActions(resolved)
            return resolved
        }
        interaction.dismissMenu()
        try await settle()
        return actions
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }

    private func capture(_ controller: UIViewController, name: String) {
        let data = UIGraphicsImageRenderer(bounds: controller.view.bounds).pngData { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(data, named: "\(name).png")
    }
}

private struct MetricsDetailFeature: View {
    let app: MobileAppModel
    let server: ServerMetric
    @State private var showsDetail = true

    var body: some View {
        Text("Metrics")
            .navigationTitle("Metrics")
            .navigationDestination(isPresented: $showsDetail) {
                MobileMetricsDetailView(app: app, server: server)
            }
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
