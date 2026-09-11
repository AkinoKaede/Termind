import SwiftUI
import UIKit

nonisolated enum MobileInterfaceIdiom: Sendable {
    case phone
    case pad

    @MainActor static var current: Self {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }
}

private struct MobileInterfaceIdiomKey: EnvironmentKey {
    static let defaultValue = MobileInterfaceIdiom.phone
}

extension EnvironmentValues {
    var mobileInterfaceIdiom: MobileInterfaceIdiom {
        get { self[MobileInterfaceIdiomKey.self] }
        set { self[MobileInterfaceIdiomKey.self] = newValue }
    }
}
