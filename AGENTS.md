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

## Architecture Records

Treat `openwiki/` as durable just-in-time engineering context. Start with `openwiki/quickstart.md` before changing dependencies, navigation ownership, state lifetimes, persistence, agent execution, permissions, secret handling, or release operations, then follow its topic-specific page to current source and tests. Source code and tests remain authoritative. Refresh invalidated OpenWiki content through the OpenWiki lifecycle and keep `ArchitectureBoundaryTests` aligned; do not maintain a parallel refactoring log.

## Build, Test, and Development Commands

- `xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile build` builds the app, the MCP bridge, and AgentKit. Keep the flag: resolving without it silently bumps pinned dependencies.
- `xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'generic/platform=iOS Simulator' -onlyUsePackageVersionsFromResolvedFile build` builds the mobile app and shared frameworks. Run its tests with an available iPhone or iPad simulator destination.
- `cd ../AgentKit && swift build && swift test` builds and tests the agent package on its own.
- `xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test` runs the default macOS and shared Swift tests. Tests that show windows or take focus are opt-in.
- `xcrun swift-format lint --strict --recursive Frameworks TFM TFI FrameworkTests TFMTests TFITests TermindMCPBridge` checks Swift formatting. AgentKit passes the same command over `Sources Tests` and must keep passing it.
- `cd LandingPage && npm ci && npm run dev` installs locked web dependencies and starts Astro locally.
- `cd LandingPage && npm run build` type-checks and emits the production site to `LandingPage/dist/`.

## Coding Style & Naming Conventions

Follow `.swift-format`: four spaces and 120 columns. Use PascalCase types, camelCase members, behavior-based test names, and matching type/file names. Preserve `ArchitectureBoundaryTests` restrictions. The site uses strict TypeScript.

## Testing Guidelines

Use Swift Testing (`@Suite`, `@Test`, `#expect`) in the three test directories. Add regression coverage and run the default test suite before submission. Web changes must pass `npm run build`; verify English and `/zh/` routes visually.

macOS tests that present windows or activate the app must use `.requiresVisibleWindow` on their suite or individual test. They are skipped by default; keep this opt-in off for routine verification. To opt in from the command line, prefix the test command with `TEST_RUNNER_TERMIND_WINDOW_TESTS=1` (Xcode forwards it as `TERMIND_WINDOW_TESTS=1` to the test host), preferably with `-only-testing:TFMTests/<Suite>` to limit the run. In Xcode, set `TERMIND_WINDOW_TESTS=1` in the test action's environment. Screenshot tests with existing dedicated opt-in variables keep those gates. Offscreen layout and logic tests remain enabled by default.

StoreKit tests require manual authorization and are also skipped by default. Run them explicitly with `TERMIND_STOREKIT_TESTS=1`, preferably with `-only-testing:TFMTests/StoreKitTrialTests`.

Mobile key-window integration suites are skipped by default because they share UIKit's process-wide presentation state. Run them explicitly with `TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1` (Xcode forwards it as `TERMIND_MOBILE_UI_TESTS=1`), `-parallel-testing-enabled NO`, and narrow `-only-testing:TFITests/<Suite>` filters.

## Localization Guidelines

Define app-facing copy as `LocalizedStringResource` entries in
`Frameworks/TermindPresentation/Strings`, including copy used by only one platform.
Reuse semantic entries and shared formatting functions from TFM and TFI; keep
protocol values, identifiers, and diagnostic codes with their existing owners.
Run `Scripts/check-presentation-copy.sh` alongside the Chinese localization check.

The two shared app catalogs are manually managed: every entry must have
`extractionState: "manual"`. A single target's extraction does not see all shared
and platform-specific copy, so its `stale` flags are not evidence that a key is
unused. Add keys and translations explicitly; verify references across both apps
and shared modules before removing a key. After editing a catalog, run
`Scripts/normalize-string-catalogs.py --write` to apply Xcode-compatible ordering
and formatting without changing translations. `Scripts/check-zh-localization.sh`
also runs the normalizer in read-only `--check` mode. Do not use `jq -S` or a
generic JSON formatter on these files: their whitespace differs from Xcode's.
The normalizer defaults to the two app catalogs and does not touch AgentKit.
Keep `STRING_CATALOG_GENERATE_SYMBOLS = NO`: `AppStrings` owns the Swift API,
and generating symbols for every manual English key introduces naming collisions.

Put user-facing app text in `Frameworks/Resources/Localizable.xcstrings` and bundle metadata in `InfoPlist.xcstrings`. Text owned by the agent runtime lives in `../AgentKit/Localizations/Localizable.xcstrings`; after editing it run `../AgentKit/Scripts/build-localizations.sh`, because `swift build` copies resources verbatim instead of compiling string catalogs. New or changed English strings require finished `zh-Hans` and `zh-Hant` translations in the same commit. Preserve placeholders and Chinese punctuation conventions. Before committing, run `Scripts/check-zh-localization.sh` (requires `jq`); it rejects invalid catalogs, missing or unfinished translations, and spacing errors. Run `AppLanguageTests` for localization behavior changes.

## Commit & Pull Request Guidelines

Use Conventional Commits: `<type>[optional scope]: <description>`, with a lowercase type and a short, imperative English description (for example, `feat: add host groups` or `fix(assistant): restore sidebar navigation round-trip`). Choose the type that matches the change:

- `feat`: new features.
- `fix`: bug fixes.
- `docs`: documentation-only changes.
- `refactor`: code restructuring without changing behavior.
- `perf`: performance improvements.
- `test`: test additions or updates.
- `style`: formatting-only changes without changing behavior.
- `build`: build system or dependency changes.
- `ci`: CI configuration or workflow changes.
- `chore`: maintenance that does not fit another type; use `chore(release): bump to X.Y.Z` for releases.
- `revert`: revert a previous commit.

Mark breaking changes with `!` before the colon (for example, `feat(api)!: remove deprecated endpoint`) and explain the impact in a `BREAKING CHANGE:` footer.

Keep commits focused. Always include `Scripts/check-zh-localization.sh` in the commit pipeline, even without intentional localization changes. PRs should describe the outcome, affected layers, verification, and issues. Include bilingual screenshots for UI changes when applicable. Never commit secrets, `.env` files, build products, or user-specific Xcode data.

<!-- OPENWIKI:START -->

## OpenWiki

This repository has a generated `openwiki/` evidence index. It is optional just-in-time context, not required startup reading.

- Treat source code and tests as authoritative. A brief's unknowns and review items are verification gaps, not automatic requirements.
- Prefer the narrowest quiet validation that proves the changed behavior. Preserve complete failure output.

The scheduled OpenWiki GitHub Actions workflow refreshes the repository wiki. Do not hand-edit generated OpenWiki pages unless explicitly asked; prefer updating source code/docs and letting OpenWiki regenerate.

<!-- OPENWIKI:END -->
