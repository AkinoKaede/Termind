import AgentKit
import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentAIWebSearchPreferences {
    @Attribute(.unique) public var key = "default"
    public var isEnabled = true
    public var prefersBuiltIn = true

    public init(_ value: AIWebSearchPreferences) { apply(value) }
    public var value: AIWebSearchPreferences {
        AIWebSearchPreferences(isEnabled: isEnabled, prefersBuiltIn: prefersBuiltIn)
    }
    public func apply(_ value: AIWebSearchPreferences) {
        isEnabled = value.isEnabled
        prefersBuiltIn = value.prefersBuiltIn
    }
}
