# Files

- [TFM Desktop UI Architecture](desktop-ui.md) - How the macOS app composes its native window shell, persistent workspace deck, split panes, management pages and Assistant surfaces, with explicit UI-state and runtime ownership.
- [Cross-Cutting Engineering Invariants](engineering-invariants.md) - Exhaustive architecture, ownership, lifecycle, security, persistence, remote-session, agent, sync, and mobile safety contracts that span Termind's specialized wiki pages.
- [TFI Mobile UI Architecture](mobile-ui.md) - How the iPhone/iPad app composes registered feature stacks, scene-local navigation, shared runtimes, adaptive content regions, native terminal/transcript surfaces and mobile interaction policies.
- [Platform Runtime, App Composition, and Lifetimes](platform-runtime.md) - How Termind composes shared services and persistence on macOS and iOS, and where app-wide, window-local, scene-local, and session state begin and end.
- [System Boundaries and Dependency Ownership](system-boundaries.md) - Static framework layers, platform composition roots, persistence ownership, and the external AgentKit boundary that keep Termind changes dependency-safe.
