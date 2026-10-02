# Files

- [macOS UI and Workspace Ownership](desktop-ui.md) - How macOS window navigation, sidebar modes, workspace sessions and Vault editing routes divide responsibility between AppModel and WindowModel.
- [Engineering invariants](engineering-invariants.md) - Cross-cutting safety rules for dependency boundaries, state lifetimes, localization, secrets, commerce, persistence, and testing, with the scope of their regression checks.
- [iOS and iPadOS UI and Scene Ownership](mobile-ui.md) - How iOS and iPadOS scenes own navigation and workspace routes while shared services own connection journeys and Metrics; covers native presentation continuity and key-window test boundaries.
- [Module map and composition roots](module-map.md) - Maps Termind's native products, six shared framework dependency targets, composition lifetimes, supporting products and pinned external package inputs.
- [Native app ownership guide](native-app-directories.md) - Ownership guide for macOS and iOS app composition, window and scene state, app-local adapters, native feature UI, and platform services.
- [Platform startup and runtime composition](platform-runtime.md) - How macOS and iOS compose shared storage and runtime services, gate scene creation on local consent, and manage window, session, background and shutdown lifetimes.
- [Shared module ownership guide](shared-module-directories.md) - Ownership and public seams of Termind's six shared frameworks and product-bundled resources, from domain values and application ports to sync, remote protocols, replay and presentation.
- [Supporting systems ownership guide](supporting-system-directories.md) - Ownership and integration boundaries for external Swift packages, the MCP bridge, Live Activities, tests, forwarding benchmarks, the Astro site, assets, and maintenance scripts.
- [System boundaries and dependency direction](system-boundaries.md) - Target dependency direction, enforced import scopes, and ownership of shared ports, persistence, external packages, and native app composition in Termind.
