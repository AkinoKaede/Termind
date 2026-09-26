# Files

- [macOS UI and Workspace Ownership](desktop-ui.md) - How macOS window navigation, sidebar modes, workspace sessions and Vault editing routes divide responsibility between AppModel and WindowModel.
- [Cross-Cutting Engineering Invariants](engineering-invariants.md) - Change-safety contracts for persistence, cloud replication, Assistant cancellation, app lifetimes and localization, with focused regression tests.
- [iOS and iPadOS UI and Scene Ownership](mobile-ui.md) - How iOS and iPadOS scene-local navigation and workspace sessions share app services, recover window ownership, and adapt presentation without replacing native state.
- [Module and Product Map](module-map.md) - Maps Termind's native products, six shared frameworks, package dependencies, composition owners, and cross-layer capabilities without mistaking folders for build boundaries.
- [Native App Responsibilities](native-app-directories.md) - Find macOS and iOS app owners for composition, window and scene state, native features, platform adapters, and local persistence without confusing them with shared services.
- [Platform Composition and Lifetimes](platform-runtime.md) - How macOS and iOS compose shared persistence and runtime services, separate app-wide from window and scene state, and handle sync, backgrounding, startup failure, and shutdown.
- [Shared Framework Responsibilities](shared-module-directories.md) - Directory ownership and collaboration across Termind's six shared frameworks and product-bundled resources, including explicit CloudKit synchronization, durable replay, and remote protocol adapters.
- [Supporting Products and Tooling](supporting-system-directories.md) - Build ownership and integration boundaries for AgentKit, the MCP bridge, Live Activities, project tests, forwarding benchmarks, the Astro website, assets, and maintenance scripts.
- [Dependency and Ownership Boundaries](system-boundaries.md) - Enforced import scopes and ownership of shared application ports, persistence adapters, remote services, and native app composition in Termind.
