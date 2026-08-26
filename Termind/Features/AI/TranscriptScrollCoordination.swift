import CoreGraphics

/// The geometry that matters when deciding whether a transcript layout change
/// should move the reader. Keeping this independent of SwiftUI makes the
/// distinction between following live content and merely repairing an invalid
/// offset explicit and testable.
nonisolated struct TranscriptScrollMetrics: Equatable, Sendable {
    let isAtBottom: Bool
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let visibleMinY: CGFloat

    var isBeyondBottom: Bool {
        visibleMinY > max(0, contentHeight - viewportHeight) + 1
    }
}

nonisolated enum TranscriptScrollAdjustment: Equatable, Sendable {
    case none
    case followBottomAfterLayout
    case repairBottomImmediately
}

nonisolated enum TranscriptScrollCoordination {
    static func adjustment(
        from old: TranscriptScrollMetrics,
        to new: TranscriptScrollMetrics,
        isFollowingBottom: Bool,
        isUserScrolling: Bool,
        isSuppressingDisclosureExpansion: Bool
    ) -> TranscriptScrollAdjustment {
        guard !isUserScrolling else { return .none }

        let contentShrank = new.contentHeight < old.contentHeight - 0.5
        let viewportChanged = abs(new.viewportHeight - old.viewportHeight) > 0.5

        // A contraction can leave AppKit's old offset below the new end of
        // the document. A composer or blocking form changing height has the
        // same effect on the viewport. Repair those changes synchronously so
        // an out-of-range viewport never becomes a blank frame.
        if contentShrank || viewportChanged {
            if isFollowingBottom || new.isBeyondBottom {
                return .repairBottomImmediately
            }
            return .none
        }

        guard new.contentHeight > old.contentHeight + 0.5 else { return .none }

        // Opening a disclosure is navigation, not new conversation output.
        // Preserve the row the reader chose instead of pulling them past it.
        if isSuppressingDisclosureExpansion { return .none }

        return isFollowingBottom ? .followBottomAfterLayout : .none
    }
}
