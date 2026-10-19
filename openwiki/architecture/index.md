# Files

- [Desktop UI and Window Ownership](desktop-ui.md) - How macOS navigation divides shared app services, per-window routes, retained native workspace views, toolbar Find ownership and feature-owned managed surfaces.
- [Engineering Invariants](engineering-invariants.md) - High-risk cross-system change checklist for operation admission, terminal context and teardown, native state lifetimes, persistence compatibility, and enforcing tests.
- [Mobile UI and Scene Ownership](mobile-ui.md) - How iPhone and iPad retain adaptive feature stacks while scenes own navigation over shared app services and in-process window workspace sessions, including recovery, remote-session selection and native-window verification.
- [Module and Dependency Map](module-map.md) - Maps Termind's native products, six shared modules, composition roots, dependency direction, and the remote package inputs actually selected by Xcode.
- [Platform Runtime and Lifetimes](platform-runtime.md) - How macOS and iOS compose shared storage and runtime services, gate scene creation on local consent, and manage window, session, background and shutdown lifetimes.
- [System Boundaries](system-boundaries.md) - Target dependency direction, enforced import scopes, and ownership of shared ports, persistence, external packages, and native app composition in Termind.
