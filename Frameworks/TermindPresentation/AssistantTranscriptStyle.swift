import Foundation
import SwiftUI

/// Shared visual semantics; each native host resolves its own fonts and colors.
nonisolated public enum AssistantTranscriptStyle {
    public static let blockSpacing: CGFloat = 10
    public static let bubbleRadius: CGFloat = 14
    public static let scanDuration: TimeInterval = 1.55
    public static let activityTextDuration: TimeInterval = 2.8
    public static let scanAlphas: [Double] = [0, 0.34, 0.82, 1, 0.82, 0.34, 0]

    public static func scanBandWidth(for width: CGFloat) -> CGFloat {
        min(max(width * 0.32, 40), 96)
    }
}

extension AgentToolPresentation.BatchTint {
    public var color: Color {
        switch self {
        case .secondary: .secondary
        case .warning: .orange
        case .success: .green
        case .failure: .red
        }
    }
}
