import SwiftUI

enum MobileFeatureSurface: Hashable, Sendable {
    case phoneTab
    case padSidebar
}

struct MobileFeaturePlacement: Hashable, Sendable {
    let surface: MobileFeatureSurface
    let order: Int
}

/// One top-level mobile destination and the surfaces that host it.
@MainActor
struct MobileFeatureRegistration: Identifiable {
    typealias Builder = (MobileAppModel, MobileSceneModel, MobileFeatureSurface) -> AnyView

    let id: MobileDestination
    let title: LocalizedStringKey
    let symbol: String
    let placements: [MobileFeaturePlacement]
    private let builder: Builder

    init(
        id: MobileDestination,
        title: LocalizedStringKey,
        symbol: String,
        placements: [MobileFeaturePlacement],
        builder: @escaping Builder
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.placements = placements
        self.builder = builder
    }

    func makeView(
        app: MobileAppModel,
        scene: MobileSceneModel,
        surface: MobileFeatureSurface
    ) -> AnyView {
        builder(app, scene, surface)
    }
}

/// The composition root for mobile navigation.
///
/// Features register their identity, placement and destination together. The
/// shell renders registrations and no longer maintains parallel tab, sidebar,
/// metadata and destination switches.
@MainActor
struct MobileFeatureRegistry {
    private(set) var registrations: [MobileFeatureRegistration] = []

    mutating func register(_ registration: MobileFeatureRegistration) {
        precondition(
            !registrations.contains { $0.id == registration.id },
            "Duplicate mobile feature registration: \(registration.id.rawValue)"
        )
        precondition(
            !registration.placements.isEmpty,
            "Mobile feature has no placement: \(registration.id.rawValue)"
        )
        registrations.append(registration)
    }

    func registrations(on surface: MobileFeatureSurface) -> [MobileFeatureRegistration] {
        var placed: [(registration: MobileFeatureRegistration, order: Int)] = []
        for registration in registrations {
            guard let placement = registration.placements.first(where: { $0.surface == surface }) else { continue }
            placed.append((registration, placement.order))
        }
        placed.sort { $0.order < $1.order }
        return placed.map(\.registration)
    }

    func registration(for destination: MobileDestination) -> MobileFeatureRegistration? {
        registrations.first { $0.id == destination }
    }

    static func standard() -> Self {
        var registry = Self()
        registry.register(
            MobileFeatureRegistration(
                id: .vault,
                title: "Vault",
                symbol: "server.rack",
                placements: [
                    MobileFeaturePlacement(surface: .phoneTab, order: 0),
                    MobileFeaturePlacement(surface: .padSidebar, order: 0),
                ]
            ) { app, scene, surface in
                AnyView(
                    MobileVaultView(
                        app: app,
                        editingHost: Binding(
                            get: { scene.editingHost },
                            set: { scene.editingHost = $0 }
                        ),
                        open: scene.open,
                        showsMetrics: surface == .phoneTab,
                        executeSnippet: scene.execute
                    ))
            }
        )
        registry.register(
            MobileFeatureRegistration(
                id: .metrics,
                title: "Metrics",
                symbol: "gauge.with.dots.needle.33percent",
                placements: [MobileFeaturePlacement(surface: .padSidebar, order: 1)]
            ) { app, _, _ in
                AnyView(MobileMetricsView(app: app))
            }
        )
        registry.register(
            MobileFeatureRegistration(
                id: .workspaces,
                title: "Workspaces",
                symbol: "terminal",
                placements: [
                    MobileFeaturePlacement(surface: .phoneTab, order: 1),
                    MobileFeaturePlacement(surface: .padSidebar, order: 2),
                ]
            ) { app, scene, _ in
                AnyView(MobileWorkspaceListView(app: app, scene: scene))
            }
        )
        registry.register(
            MobileFeatureRegistration(
                id: .assistant,
                title: "Assistant",
                symbol: "sparkles",
                placements: [
                    MobileFeaturePlacement(surface: .phoneTab, order: 2),
                    MobileFeaturePlacement(surface: .padSidebar, order: 3),
                ]
            ) { app, scene, _ in
                AnyView(
                    MobileAssistantView(
                        app: app,
                        model: scene.assistant,
                        libraryRoute: Binding(
                            get: { scene.assistantLibraryRoute },
                            set: { scene.assistantLibraryRoute = $0 }
                        )
                    ))
            }
        )
        registry.register(
            MobileFeatureRegistration(
                id: .settings,
                title: "Settings",
                symbol: "gearshape",
                placements: [
                    MobileFeaturePlacement(surface: .phoneTab, order: 3),
                    MobileFeaturePlacement(surface: .padSidebar, order: 4),
                ]
            ) { app, _, _ in
                AnyView(MobileSettingsView(app: app))
            }
        )
        return registry
    }
}
