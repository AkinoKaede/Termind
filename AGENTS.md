# Repository Guidelines

## Project Structure & Module Organization

`Termind.xcodeproj` is the single project. `TFM/` contains the Swift 6 macOS app,
`TFI/` the iPhone/iPad app. Their targets and schemes are `TFM` and `TFI`.
`Frameworks/` contains static `TermindDomain`, `TermindApplication`,
`TermindInfrastructure`, and `TermindPersistence` frameworks. All SwiftData models,
historical schemas, and the container factory belong exclusively to Persistence.
`Frameworks/Resources/` is compiled into each app bundle. Platform adapters and UI
stay with their app; shared modules must never depend on an app target.
`TermindMCPBridge/` builds `termind-mcp` for macOS only. Tests are separated into
`FrameworkTests/`, `TFMTests/`, and `TFITests/` with matching targets.
`LandingPage/` is the Astro site. Utilities belong in `Scripts/`.

The agent runtime is `AgentKit`, a separate open-source package developed in the sibling `../AgentKit` repository and consumed as a versioned remote SPM dependency on `github.com/AkinoKaede/AgentKit`, pinned in `Package.resolved`. It owns the loop, the approval gate, the provider adapters, the MCP client, and the built-in tools that know nothing about hosts. Termind owns the SSH/SFTP tools and registers them through `TermindAgentTools`. Never add SSH, SFTP, UI, or the name Termind to that package.

Xcode builds the pinned tag, not the sibling working tree, so an uncommitted change in `../AgentKit` is invisible to the app. A change that spans both sides takes three steps: make and test the package change, tag and push a release from `../AgentKit`, then bump `minimumVersion` in `project.pbxproj` and re-resolve so `Package.resolved` records the new revision. Both files belong in the same commit as the app-side change that needs them.

## Architecture Records & Refactoring Memory

Treat `Memory/` as durable engineering context. Read `ARCHITECTURE.md` before changing dependencies, navigation ownership, state lifetimes, persistence, agent execution, permissions, or secret handling. Update invalidated invariants and keep `ArchitectureBoundaryTests` aligned.

`REFACTOR.md` is the English-only redundancy backlog. Lifecycle: confirm an item with `rg` → record evidence, action, and estimated reduction → implement one independent, code-reducing change → run risk-appropriate tests → mark its status and verification. Append rather than rewrite, retain completed items, and preserve SwiftUI/AppKit boundaries.

## Build, Test, and Development Commands

- `xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile build` builds the app, the MCP bridge, and AgentKit. Keep the flag: resolving without it silently bumps pinned dependencies.
- `xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'generic/platform=iOS Simulator' -onlyUsePackageVersionsFromResolvedFile build` builds the mobile app and shared frameworks. Run its tests with an available iPhone or iPad simulator destination.
- `cd ../AgentKit && swift build && swift test` builds and tests the agent package on its own.
- `xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test` runs all Swift tests.
- `xcrun swift-format lint --strict --recursive Frameworks TFM TFI FrameworkTests TFMTests TFITests TermindMCPBridge` checks Swift formatting. AgentKit passes the same command over `Sources Tests` and must keep passing it.
- `cd LandingPage && npm ci && npm run dev` installs locked web dependencies and starts Astro locally.
- `cd LandingPage && npm run build` type-checks and emits the production site to `LandingPage/dist/`.

## Coding Style & Naming Conventions

Follow `.swift-format`: four spaces and 120 columns. Use PascalCase types, camelCase members, behavior-based test names, and matching type/file names. Preserve `ArchitectureBoundaryTests` restrictions. The site uses strict TypeScript.

## Testing Guidelines

Use Swift Testing (`@Suite`, `@Test`, `#expect`) in the three test directories. Add regression coverage and run all tests before submission. Web changes must pass `npm run build`; verify English and `/zh/` routes visually.

## Localization Guidelines

Put user-facing app text in `Frameworks/Resources/Localizable.xcstrings` and bundle metadata in `InfoPlist.xcstrings`. Text owned by the agent runtime lives in `../AgentKit/Localizations/Localizable.xcstrings`; after editing it run `../AgentKit/Scripts/build-localizations.sh`, because `swift build` copies resources verbatim instead of compiling string catalogs. New or changed English strings require finished `zh-Hans` translations in the same commit. Preserve placeholders and Chinese punctuation conventions. Before committing, run `Scripts/check-zh-localization.sh` (requires `jq`); it rejects invalid catalogs, missing or unfinished translations, and spacing errors. Run `AppLanguageTests` for localization behavior changes.

## Commit & Pull Request Guidelines

Use short, imperative subjects such as `Fix Assistant sidebar navigation round-trip`; reserve `Bump to X.Y.Z` for releases. Keep commits focused. Always include `Scripts/check-zh-localization.sh` in the commit pipeline, even without intentional localization changes. PRs should describe the outcome, affected layers, verification, and issues. Include bilingual screenshots for UI changes when applicable. Never commit secrets, `.env` files, build products, or user-specific Xcode data.
