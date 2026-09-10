#if DEBUG
    import AppKit
    import SwiftData
    import SwiftUI

    /// The screenshot host uses the production view tree, with an explicit
    /// NSWindow so it does not depend on SwiftUI's restored launch windows.
    @MainActor
    enum ScreenshotDemoWindow {
        private static var createWindow: (() -> NSWindow)?
        private static var window: NSWindow?
        private(set) static var model: AppModel?

        static func configure(
            app: AppModel, windowModel: WindowModel, container: ModelContainer, locale: Locale
        ) {
            model = app
            createWindow = {
                let view = RootView(window: windowModel)
                    .environment(app)
                    .environment(\.locale, locale)
                    .modelContainer(container)
                    .proPaywallPresenter(app: app)
                let controller = NSHostingController(rootView: view)
                let window = NSWindow(
                    contentRect: NSRect(
                        x: 0, y: 0, width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.isRestorable = false
                window.toolbarStyle = .unifiedCompact
                window.contentViewController = controller
                return window
            }
        }

        static func present() {
            guard window == nil, let createWindow else { return }
            let value = createWindow()
            window = value
            value.makeKeyAndOrderFront(nil)
        }
    }
#endif
