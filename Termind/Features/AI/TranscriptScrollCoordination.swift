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
        isSuppressingDisclosureLayout: Bool
    ) -> TranscriptScrollAdjustment {
        guard !isUserScrolling else { return .none }

        let contentShrank = new.contentHeight < old.contentHeight - 0.5
        let viewportChanged = abs(new.viewportHeight - old.viewportHeight) > 0.5

        // A contraction can leave AppKit's old offset below the new end of
        // the document. A composer or blocking form changing height has the
        // same effect on the viewport.
        if contentShrank || viewportChanged {
            // An out-of-range viewport is a blank frame whatever caused it, so
            // repair it synchronously before asking who asked for the change.
            if new.isBeyondBottom { return .repairBottomImmediately }
            // Closing a disclosure is navigation, exactly like opening one: the
            // reader asked to see less, not to be taken to the live edge.
            if isSuppressingDisclosureLayout { return .none }
            return isFollowingBottom ? .repairBottomImmediately : .none
        }

        guard new.contentHeight > old.contentHeight + 0.5 else { return .none }

        // Opening a disclosure is navigation, not new conversation output.
        // Preserve the row the reader chose instead of pulling them past it.
        if isSuppressingDisclosureLayout { return .none }

        return isFollowingBottom ? .followBottomAfterLayout : .none
    }
}
