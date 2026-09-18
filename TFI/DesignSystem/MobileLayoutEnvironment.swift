import Observation
import SwiftUI

nonisolated enum MobileLayout: Sendable {
    case compact
    case regular

    init(sizeClass: UserInterfaceSizeClass?) {
        self = sizeClass == .regular ? .regular : .compact
    }
}

/// A window delays navigation reconstruction until saves and their error feedback finish.
@MainActor @Observable
final class MobileLayoutTransition {
    private var saves: Set<UUID> = []
    var isBlocked: Bool { !saves.isEmpty }

    func beginSave() -> UUID {
        let id = UUID()
        saves.insert(id)
        return id
    }

    func endSave(_ id: UUID) { saves.remove(id) }
}

extension EnvironmentValues {
    @Entry var mobileLayout: MobileLayout? = nil
    @Entry var mobileLayoutTransition: MobileLayoutTransition? = nil
}
