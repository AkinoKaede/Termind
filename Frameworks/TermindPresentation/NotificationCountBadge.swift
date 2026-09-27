import SwiftUI

public struct NotificationCountBadge: View {
    private let count: Int

    public init(_ count: Int) {
        self.count = count
    }

    public var body: some View {
        if count > 0 {
            Text(verbatim: count > 99 ? "99+" : String(count))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 14, minHeight: 14)
                .background(.red, in: Capsule())
                .overlay { Capsule().stroke(.background, lineWidth: 1) }
                .fixedSize()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}
