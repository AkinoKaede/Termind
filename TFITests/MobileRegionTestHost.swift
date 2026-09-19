import SwiftUI

@testable import TermindIOS

@Observable @MainActor final class MobileRegionTestState {
    var regions: [MobileReservedRegion] = []
    var toolbarLayout = MobileToolbarLayout()
}

struct MobileRegionTestHost<Content: View>: View {
    var state: MobileRegionTestState?
    @ViewBuilder var content: () -> Content

    var body: some View { content().environment(\.mobileReservedRegions, state?.regions) }
}
