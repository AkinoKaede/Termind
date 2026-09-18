import Foundation

/// Device-local content dimensions. A nil defaults store keeps tests and demos
/// in memory; scene restoration remains responsible for individual window frames.
@MainActor
final class MainWindowSizeStore {
    private let defaults: UserDefaults?
    private(set) var size: CGSize?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let values = defaults?.array(forKey: DesktopSettingsKey.mainWindowSize) as? [Double],
            values.count == 2
        {
            let candidate = CGSize(width: values[0], height: values[1])
            if Self.isValid(candidate) { size = candidate }
        }
    }

    var defaultSize: CGSize {
        size ?? CGSize(width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight)
    }

    func save(_ size: CGSize) {
        guard Self.isValid(size), size != self.size else { return }
        self.size = size
        defaults?.set([Double(size.width), Double(size.height)], forKey: DesktopSettingsKey.mainWindowSize)
    }

    static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
