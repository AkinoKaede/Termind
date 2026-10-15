import CoreGraphics

/// Mobile layout values shared by managed collection surfaces.
nonisolated enum MobileCardLayout {
    static let minimumHeight: CGFloat = 106
    static let compactMinimumWidth: CGFloat = 76
    static let compactMaximumColumns = 4
    static let maximumVisibleTags = 2

    static func columns(
        width: CGFloat, accessibilitySize: Bool, compact: Bool = false,
        compactWidth: CGFloat = compactMinimumWidth
    ) -> Int {
        guard !accessibilitySize else { return 1 }
        let minimumWidth = compact ? max(compactMinimumWidth, compactWidth) : 320
        let count = max(1, Int((max(0, width) + 12) / (minimumWidth + 12)))
        return compact ? min(compactMaximumColumns, count) : count
    }

    static func visibleTags(_ tags: [String]) -> ArraySlice<String> {
        tags.prefix(maximumVisibleTags)
    }
}
