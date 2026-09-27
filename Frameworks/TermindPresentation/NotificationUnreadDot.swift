import SwiftUI

public struct NotificationUnreadDot: View {
    public init() {}
    public var body: some View {
        Circle().fill(.blue).frame(width: 7, height: 7)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
