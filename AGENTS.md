# Repository Guidelines

## Project Structure & Module Organization

`Termind/` contains the Swift 6 macOS app: models in `Domain/`, orchestration and ports in `Application/`, adapters in `Infrastructure/`, UI in `Features/`, and macOS integration in `Platform/macOS/`. `TermindMCPBridge/` builds `termind-mcp`; tests live in `TermindTests/`. `LandingPage/` is the Astro site. Utilities belong in `Scripts/`.

## Architecture Records & Refactoring Memory

Treat `Memory/` as durable engineering context. Read `ARCHITECTURE.md` before changing dependencies, navigation ownership, state lifetimes, persistence, agent execution, permissions, or secret handling. Update invalidated invariants and keep `ArchitectureBoundaryTests` aligned.

`REFACTOR.md` is the English-only redundancy backlog. Lifecycle: confirm an item with `rg` → record evidence, action, and estimated reduction → implement one independent, code-reducing change → run risk-appropriate tests → mark its status and verification. Append rather than rewrite, retain completed items, and preserve SwiftUI/AppKit boundaries.

## Build, Test, and Development Commands

- `xcodebuild -project Termind.xcodeproj -scheme Termind -destination 'platform=macOS' build` builds the app and MCP bridge.
- `xcodebuild -project Termind.xcodeproj -scheme Termind -destination 'platform=macOS' test` runs all Swift tests.
- `xcrun swift-format lint --strict --recursive Termind TermindTests TermindMCPBridge` checks Swift formatting.
- `cd LandingPage && npm ci && npm run dev` installs locked web dependencies and starts Astro locally.
- `cd LandingPage && npm run build` type-checks and emits the production site to `LandingPage/dist/`.

## Coding Style & Naming Conventions

Follow `.swift-format`: four spaces and 120 columns. Use PascalCase types, camelCase members, behavior-based test names, and matching type/file names. Preserve `ArchitectureBoundaryTests` restrictions. The site uses strict TypeScript.

## Testing Guidelines

Use Swift Testing (`@Suite`, `@Test`, `#expect`) in `TermindTests/*Tests.swift`. Add regression coverage and run all tests before submission. Web changes must pass `npm run build`; verify English and `/zh/` routes visually.

## Localization Guidelines

Put user-facing app text in `Termind/Resources/Localizable.xcstrings` and bundle metadata in `InfoPlist.xcstrings`. New or changed English strings require finished `zh-Hans` translations in the same commit. Preserve placeholders and Chinese punctuation conventions. Before committing, run `Scripts/check-zh-localization.sh` (requires `jq`); it rejects invalid catalogs, missing or unfinished translations, and spacing errors. Run `AppLanguageTests` for localization behavior changes.

## Commit & Pull Request Guidelines

Use short, imperative subjects such as `Fix Assistant sidebar navigation round-trip`; reserve `Bump to X.Y.Z` for releases. Keep commits focused. Always include `Scripts/check-zh-localization.sh` in the commit pipeline, even without intentional localization changes. PRs should describe the outcome, affected layers, verification, and issues. Include bilingual screenshots for UI changes when applicable. Never commit secrets, `.env` files, build products, or user-specific Xcode data.
