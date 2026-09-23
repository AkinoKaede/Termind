import Foundation
import SwiftUI

extension LocalizedStringResource {
    /// Bridges resource-backed copy to SwiftUI APIs that accept keys on our
    /// minimum OS versions. Resource interpolation preserves its localization
    /// metadata; converting the resource to an ordinary String would lose it.
    public var swiftUIKey: LocalizedStringKey { "\(self)" }
}
