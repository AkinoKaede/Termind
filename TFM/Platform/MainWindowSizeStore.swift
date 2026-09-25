import Foundation

/// Device-local content dimensions. A nil defaults store keeps tests and demos
/// in memory; scene restoration remains responsible for individual window frames.
@MainActor
final class MainWindowSizeStore {
    private let defaults: UserDefaults?
    private(set) var size: CGSize?
    private(set) var sidebarWidth: CGFloat?
    private(set) var showsSidebar: Bool?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let values = defaults?.array(forKey: DesktopSettingsKey.mainWindowSize) as? [Double],
            values.count == 2
        {
            let candidate = CGSize(width: values[0], height: values[1])
            if Self.isValid(candidate) { size = candidate }
        }
        if let value = defaults?.object(forKey: DesktopSettingsKey.mainWindowSidebarWidth) as? Double,
            Self.isValidSidebarWidth(CGFloat(value))
        {
            sidebarWidth = CGFloat(value)
        }
        showsSidebar = defaults?.object(forKey: DesktopSettingsKey.mainWindowShowsSidebar) as? Bool
    }

    var defaultSize: CGSize {
        size ?? CGSize(width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight)
    }

    var defaultSidebarWidth: CGFloat { sidebarWidth ?? Metrics.Sidebar.ideal }
    var defaultShowsSidebar: Bool { showsSidebar ?? true }

    func save(_ size: CGSize) {
        guard Self.isValid(size), size != self.size else { return }
        self.size = size
        defaults?.set([Double(size.width), Double(size.height)], forKey: DesktopSettingsKey.mainWindowSize)
    }

    func saveSidebar(width: CGFloat, isPresented: Bool) {
        guard Self.isValidSidebarWidth(width) else { return }
        if sidebarWidth != width {
            sidebarWidth = width
            defaults?.set(Double(width), forKey: DesktopSettingsKey.mainWindowSidebarWidth)
        }
        if showsSidebar != isPresented {
            showsSidebar = isPresented
            defaults?.set(isPresented, forKey: DesktopSettingsKey.mainWindowShowsSidebar)
        }
    }

    static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    static func isValidSidebarWidth(_ width: CGFloat) -> Bool {
        width.isFinite && (Metrics.Sidebar.min...Metrics.Sidebar.max).contains(width)
    }
}
