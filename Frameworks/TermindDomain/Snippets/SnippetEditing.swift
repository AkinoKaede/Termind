import Foundation

nonisolated

    extension Snippet
{
    public func duplicated() -> Snippet {
        var copy = self
        copy.id = UUID()
        copy.title = String(localized: "\(title) Copy")
        copy.sortIndex = 0
        return copy
    }
}
