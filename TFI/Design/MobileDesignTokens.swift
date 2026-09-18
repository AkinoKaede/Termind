import CoreGraphics

/// Mobile layout values shared by managed collection surfaces.
nonisolated enum MobileCardLayout {
    static let minimumHeight: CGFloat = 104
    static let maximumVisibleTags = 2

    static func columns(width: CGFloat, accessibilitySize: Bool) -> Int {
        guard !accessibilitySize else { return 1 }
        return max(1, Int((max(0, width) + 12) / 332))
    }

    static func visibleTags(_ tags: [String]) -> ArraySlice<String> {
        tags.prefix(maximumVisibleTags)
    }
}
