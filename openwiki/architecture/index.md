# Files

- [Desktop UI and Window Ownership](desktop-ui.md) - How desktop navigation and persistent workspace views divide app-wide and per-window state, and how native window registration, close vetoes and application Quit manage their lifetimes.
- [Engineering Invariants](engineering-invariants.md) - Cross-cutting safety rules for dependency boundaries, state lifetimes, localization, secrets, commerce, persistence, and testing, with the scope of their regression checks.
- [iOS and iPadOS UI and Scene Ownership](mobile-ui.md) - How iOS and iPadOS scenes own navigation and workspace routes while shared services own connection journeys and Metrics; covers native presentation continuity and key-window test boundaries.
- [Module Map and Composition Roots](module-map.md) - Maps Termind's native products, six shared framework dependency targets, composition lifetimes, supporting products and pinned external package inputs.
- [Native App Ownership and Source Landmarks](native-app-directories.md) - Ownership guide for macOS and iOS app composition, window and scene state, app-local adapters, native feature UI, and platform services.
- [Platform Runtime and Service Lifetimes](platform-runtime.md) - How macOS and iOS compose shared storage and runtime services, gate scene creation on local consent, and manage window, session, background and shutdown lifetimes.
- [Shared Module Ownership and Source Landmarks](shared-module-directories.md) - Ownership and public seams of Termind's six shared frameworks and product-bundled resources, from domain values and application ports to sync, remote protocols, replay and presentation.
- [Supporting Products and Tooling Boundaries](supporting-system-directories.md) - Ownership and integration boundaries for external Swift packages, the MCP bridge, Live Activities, tests, forwarding benchmarks, the Astro site, assets, and maintenance scripts.
- [System Boundaries and Change Placement](system-boundaries.md) - Target dependency direction, enforced import scopes, and ownership of shared ports, persistence, external packages, and native app composition in Termind.
