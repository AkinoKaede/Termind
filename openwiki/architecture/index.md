# Files

- [Desktop Navigation and UI Ownership](desktop-ui.md) - How macOS navigation divides shared app services, per-window routes, retained native workspace views, toolbar Find ownership and feature-owned managed surfaces.
- [Engineering Invariants and Change Safety](engineering-invariants.md) - Cross-cutting safety rules for dependency boundaries, state lifetimes, localization, secrets, commerce, persistence, and testing, with the scope of their regression checks.
- [Mobile Navigation and Presentation Ownership](mobile-ui.md) - How iPhone and iPad retain adaptive feature stacks while scenes own navigation and presentation over shared app services and persistent window workspace sessions; includes History routing and native-window verification.
- [Module Ownership and Composition Roots](module-map.md) - Maps Termind's native products, six shared modules, composition roots, dependency direction, and the remote package inputs actually selected by Xcode.
- [Native Runtime and State Lifetimes](platform-runtime.md) - How macOS and iOS compose shared storage and runtime services, gate scene creation on local consent, and manage window, session, background and shutdown lifetimes.
- [System Boundaries and Dependency Contracts](system-boundaries.md) - Target dependency direction, enforced import scopes, and ownership of shared ports, persistence, external packages, and native app composition in Termind.
