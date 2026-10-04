import SwiftUI
import TermindPresentation

/// One top-level mobile destination.
@MainActor
struct MobileFeatureRegistration: Identifiable {
    typealias Builder = (MobileAppModel, MobileSceneModel) -> AnyView

    let id: MobileDestination
    let title: LocalizedStringResource
    let symbol: String
    private let builder: Builder

    init(
        id: MobileDestination,
        title: LocalizedStringResource,
        symbol: String,
        builder: @escaping Builder
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.builder = builder
    }

    func makeView(
        app: MobileAppModel,
        scene: MobileSceneModel
    ) -> AnyView {
        builder(app, scene)
    }
}

/// The composition root for mobile navigation.
///
/// Features register their identity, order and destination together. The
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
        registrations.append(registration)
    }

    static func standard() -> Self {
        var registry = Self()
        registry.register(
            MobileFeatureRegistration(
                id: .vault,
                title: AppStrings.Navigation.vault,
                symbol: "server.rack"
            ) { app, scene in
                AnyView(
                    MobileVaultView(
                        app: app,
                        reviewScene: scene,
                        editingHost: Bindable(scene).projectedValue.editingHost,
                        activateHost: scene.activateHost,
                        open: scene.open,
                        executeSnippet: scene.execute,
                        openMetrics: { scene.selectedDestination = .metrics }
                    ))
            }
        )
        registry.register(
            MobileFeatureRegistration(
                id: .metrics,
                title: AppStrings.Navigation.metrics,
                symbol: "waveform.path.ecg"
            ) { app, _ in
                AnyView(MobileMetricsView(app: app))
            }
        )
        registry.register(
            MobileFeatureRegistration(
                id: .workspaces,
                title: AppStrings.Navigation.workspaces,
                symbol: "terminal"
            ) { app, scene in
                AnyView(MobileWorkspaceListView(app: app, scene: scene))
            }
        )
        registry.register(
            MobileFeatureRegistration(
                id: .assistant,
                title: AppStrings.Navigation.assistant,
                symbol: "sparkles"
            ) { app, scene in
                AnyView(
                    MobileAssistantView(
                        app: app,
                        model: scene.assistant,
                        libraryRoute: Bindable(scene).projectedValue.assistantLibraryRoute
                    ))
            }
        )
        registry.register(
            MobileFeatureRegistration(
                id: .settings,
                title: AppStrings.Navigation.settings,
                symbol: "gearshape"
            ) { app, scene in
                AnyView(MobileSettingsView(app: app, reviewScene: scene))
            }
        )
        return registry
    }
}
