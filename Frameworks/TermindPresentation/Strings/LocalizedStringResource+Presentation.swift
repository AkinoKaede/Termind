import Foundation
import SwiftUI

extension LocalizedStringResource {
    /// Bridges resource-backed copy to SwiftUI APIs that accept keys on our
    /// minimum OS versions. Resource interpolation preserves its localization
    /// metadata; converting the resource to an ordinary String would lose it.
    /// APIs with a `LocalizedStringResource` overload, notably
    /// `confirmationDialog`, should receive the resource directly because
    /// UIKit-backed presentations can expose interpolated locale metadata.
    public var swiftUIKey: LocalizedStringKey { "\(self)" }
}
