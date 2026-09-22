---
type: product-surface-concept
title: Commerce, Localization, and Product Surfaces
description: Explains StoreKit-derived Pro access, native paywall and review ownership, localization completion rules, and the app, widget, screenshot, and marketing-site surfaces that present the product.
tags: [commerce, storekit, localization, product-surfaces, marketing, widgets]
verified:
  - by: openwiki/0.5.2
    at: 2026-09-22T00:31:10.149Z
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-b2f57db7a90dcc30dd3886da
    resource: repo://Frameworks/TermindApplication/FeatureModels/AppReviewController.swift
  - id: openwiki-source-b37c974aaea12bd08606d67d
    resource: repo://Frameworks/TermindDomain/Commerce/ProAccessTypes.swift
  - id: openwiki-source-3aa42bdd0f8eaf866f06599f
    resource: repo://Frameworks/TermindInfrastructure/Commerce/ProAccessController.swift
  - id: openwiki-source-eae5d91412d0e2847dacd5b6
    resource: repo://FrameworkTests/AppReviewControllerTests.swift
  - id: openwiki-source-103853faf6b28763354a1c79
    resource: repo://LandingPage/package.json
  - id: openwiki-source-554fe71f1ba6efebee0d020c
    resource: repo://LandingPage/src/lib/marketingImages.ts
  - id: openwiki-source-35f05e7077ecf965940a0dd7
    resource: repo://Memory/MARKETING.md
  - id: openwiki-source-41a7ded3800c9422f058a3ef
    resource: repo://Scripts/check-zh-localization.sh
  - id: openwiki-source-60d4159ef162d09de4f4b469
    resource: repo://Scripts/run-screenshot-demo.sh
  - id: openwiki-source-9fc915d39c61b81a60426eb3
    resource: repo://StoreKit/Termind.storekit
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-e43a0da5ab77c2fc3554244d
    resource: repo://TFI/App/MobileSceneModel.swift
  - id: openwiki-source-0ffab0ae6452f870ce4a0efe
    resource: repo://TFI/Features/Commerce/MobileProView.swift
  - id: openwiki-source-4bb1006b8fba7cd74268940b
    resource: repo://TFI/Features/Settings/MobileMCPSettings.swift
  - id: openwiki-source-4c2de67bfdb2238d765a642a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceView.swift
  - id: openwiki-source-637644793f7e37cc057eb973
    resource: repo://TFI/Platform/MobileLiveActivityController.swift
  - id: openwiki-source-d1ffd558b3360478aa85b5af
    resource: repo://TFIWidgets/WorkspaceLiveActivity.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-2b65afedbf9d80b1d387f50a
    resource: repo://TFM/App/ScreenshotDemo.swift
  - id: openwiki-source-766dc23f16ac26a41a5b5c22
    resource: repo://TFM/Features/Commerce/ProPaywallView.swift
  - id: openwiki-source-0da64bbb5811b467bbf89b7f
    resource: repo://TFMTests/ProAccessTests.swift
  - id: openwiki-source-0dd012e3740bcc348fc36ccb
    resource: repo://TFMTests/StoreKitTrialTests.swift
  - id: openwiki-source-0f8d0f9d08d6674698dd054c
    resource: repo://WorkspaceActivitySupport/WorkspaceActivityAttributes.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-22T00:31:10.149Z" }
---

## Scope and ownership

Termind keeps the commercial decision inside the shared infrastructure and domain layers, rather than treating a screen as the source of truth. `ProAccessController` is the observable, main-actor StoreKit adapter used by both app targets; `EntitlementStatus` and `ProFeature` define the shared access contract. Native macOS and iOS views own their respective paywall presentation and subscription-management affordances, while StoreKit supplies localized products, prices, billing periods, eligibility, and purchase outcomes. The checked-in `StoreKit/Termind.storekit` configuration is a local test fixture; App Store Connect remains the production storefront authority.

The two supported products are the family-shareable lifetime non-consumable `com.akinokaede.termind.pro` and the family-shareable annual auto-renewable subscription `com.akinokaede.termind.pro.annual`. The local configuration defines the annual product as yearly with a two-week free introductory offer, but UI must use StoreKit metadata rather than hard-coded storefront price, period, or eligibility.

## Entitlement-derived Pro access

`ProFeature` is the complete gate vocabulary: AI Assistant, terminal-file upload, remote MCP, the built-in MCP server, Vault/iCloud sync, and unlimited Metrics. Callers must use `canUse` to condition state or `require` immediately before the protected action. `require` records the requested feature and raises the shared paywall flag when access is absent, preventing a caller from continuing merely because it can render a control.

```mermaid
flowchart TD
    Launch["Controller starts"] --> Observe["Observe transaction updates"]
    Launch --> Refresh["Read current entitlements"]
    Refresh --> Lifetime{"Verified lifetime entitlement"}
    Lifetime -->|yes| LifetimeAccess["Lifetime Pro access"]
    Lifetime -->|no| Annual["Read latest annual transaction"]
    Annual --> Subscription["Classify subscription phase"]
    Subscription --> Granted{"Trial subscribed or grace"}
    Granted -->|yes| Pro["Pro feature is allowed"]
    Granted -->|no| Free["Feature requires native paywall"]
    Observe --> Refresh
```

This shows the entitlement resolution path used by `ProAccessController`; product metadata loading is separate from access resolution.

Access is based only on verified StoreKit transactions. A valid, non-revoked lifetime entitlement takes precedence over annual status. An annual transaction grants Pro during an introductory trial, active subscription, or verified grace period; billing retry, expiry, revocation, and verification failure do not. Cancellation does not itself remove access before expiry. The controller consumes `Transaction.updates`, including deferred Ask to Buy approval, finishes verified transactions after refresh, and schedules another refresh at a currently access-granting entitlement's expiration. It refreshes independently from product metadata, so a metadata/network failure clears offers and reports a recoverable catalog error without taking away already verified access.

The controller serializes duplicate operations: it prevents a second purchase while processing or pending, tracks the specific pending product, treats user cancellation as non-error, and uses `AppStore.sync()` followed by a refresh for Restore Purchase. A successful verified purchase or restore closes the paywall; a restore without qualifying entitlement reports that no active purchase was found.

### What remains free

The gate set is intentionally narrower than the product’s general remote-workspace experience. Free users can still use the ordinary workspace, SSH/SFTP work, Vault, settings, and the first three Metrics cards. The enforced boundaries are: assistant execution; dropping files onto an SSH terminal; creating/editing/connecting remote MCP servers; enabling or resuming the built-in macOS MCP server; iCloud Vault, Metrics, and Settings synchronization; and Metrics cards beyond three. When Pro sync is unavailable, sync services pause rather than attempting background synchronization; when built-in MCP access is lost, an enabled server is suspended. Local Vault and workspace data are not erased by that transition.

### Native paywalls

Both platforms render native SwiftUI commerce views from the same controller, but presentation is platform-owned. macOS uses a shared `ProPaywallPresenter` to elect one main-window sheet owner; iOS presents `MobileProView` as a native sheet and invokes the system subscription-management sheet. Both offer annual/lifetime selection, StoreKit-derived offer details, restore, privacy and terms links, and communicate that Family Sharing is supported and AI-provider charges are separate. On macOS, subscription management uses Apple’s account URL; only a purchaser-owned subscription is eligible for management controls, not family-shared access.

## Review invitation policy

`AppReviewController` centralizes the cross-platform budget for asking StoreKit to show a review prompt. It persists attempts—not presentations, ratings, or completions, which StoreKit does not reveal—and is deliberately disabled under XCTest. A live controller observes active app surfaces and may arm a request only after an active workspace-to-approved-review-page transition. Mac review pages are selected Vault pages plus Settings and App Settings; mobile additionally enumerates Vault hosts, Keychain, snippets, and known-hosts pages.

Eligibility requires at least seven days since first use, three distinct active local dates, five minutes of foreground workspace time, no prior request for the current app version, and at least 120 days since the prior attempt. After the qualifying transition it waits three seconds, then records the version and attempt timestamp *before* calling `requestReview`. Interactions, navigation, blocked presentation, focus changes, surface removal, or activation of another surface cancel a pending invitation. Presenters also block while onboarding, editors/routes, errors, external authentication, or Pro commerce is active. The explicit “write a review” link records an attempt and restarts cooldown, but does not claim that a rating occurred.

## Localization as a release invariant

User-facing app strings belong in `Frameworks/Resources/Localizable.xcstrings`, which is compiled into every app bundle; bundle metadata belongs in `InfoPlist.xcstrings`. The separate AgentKit runtime owns its own `../AgentKit/Localizations/Localizable.xcstrings`; its catalog must be rebuilt with `../AgentKit/Scripts/build-localizations.sh` after changes because a plain Swift build copies those resources rather than compiling them.

Any new or changed English app string requires completed `zh-Hans` and `zh-Hant` translations in the same commit. Preserve placeholders and Chinese punctuation conventions. `Scripts/check-zh-localization.sh` requires `jq` and rejects invalid catalog JSON, missing locale entries, unfinished string units, and Chinese/Latin or punctuation spacing violations. Run it in the normal commit pipeline even when localization was not intentionally changed; run `AppLanguageTests` when behavior changes. Product configuration likewise carries English, Simplified Chinese, and Traditional Chinese names and descriptions, so App Store Connect updates must remain synchronized with the local fixture and the localized product copy.

## Mobile Live Activity and widget boundary

The widget extension is an iOS product surface, not a second workspace implementation: `TermindWidgets` exposes only `WorkspaceLiveActivity`. The app serializes all activity start, update, and end operations to avoid close-last/open-new races, retains at most one restored active or stale activity, and ends duplicates. It starts only after an explicit workspace opening intent and `ActivityKit` permits it; ordinary updates cannot resurrect a user-dismissed activity. It ends the activity when no workspaces remain.

The activity payload deliberately excludes credentials and terminal output. It provides aggregate counts and up to six focused-first workspace summaries, truncating titles to fit payload/layout limits. The Lock Screen and Dynamic Island expose deep links for the focused activity or individual visible workspaces; the app accepts only strict `termind://workspaces` and UUID-shaped `termind://workspace/<id>` routes, switching to the list or selected workspace respectively. The widget adapts the session row from six to five or four entries to fit, and supplies an All Workspaces link when summaries are omitted.

## Demo, screenshots, and marketing-site boundary

Screenshot/demo data must not modify production behavior. In DEBUG macOS builds, `ScreenshotDemoConfiguration` parses exactly one `--termind-demo=<scene>:<language>` argument and fails fast on duplicate, malformed, unknown scene, or unsupported language input. It binds the fixture scene and `AppLanguage` together, supporting `en`, `zh-Hans`, and `zh-Hant`; the helper script builds the pinned TFM scheme and launches the app with matching Apple language/locale overrides. Demo content uses isolated in-memory models and bundled fixture hosts, with preconditions when required fixtures are absent.

Marketing capture uses real feature views with fixture-only data: mobile tests mount real views in system windows, while macOS captures the production `WindowGroup` through `ScreenshotDemoConfiguration`. Asset source captures are organized by feature/device/locale; the sanctioned locales are `en`, `zh-hans`, and `zh-hant`. UI chrome and marketing copy are localized, while terminal command and transcript content remains English. A UI change affecting a captured scene must be recaptured in every locale rather than fabricating missing platform UI or changing product behavior for an image.

The public site is a separate Astro app in `LandingPage/`, with strict TypeScript and `npm run build` running `astro check && astro build`. It imports an explicit allowlist of framed marketing images through `src/lib/marketingImages.ts`; do not copy marketing sources into `LandingPage/public`. Its formal routes are English `/`, Simplified Chinese `/zh-hans/`, and Traditional Chinese `/zh-hant/`; compatibility `/zh/` redirects to Simplified Chinese. Website work must validate the production build and visually check English plus Chinese routes. App Store screenshots and storefront metadata remain release artifacts, not runtime app configuration.

## Change and verification guide

- For an access change, update `ProFeature`/callers and `ProAccessController` together; test entitlement phases, verification failures, pending Ask to Buy, restore, and metadata failure separately. `StoreKitTrialTests` exercises the local `SKTestSession` configuration, while `CommerceConfigurationTests` catches drift between product identifiers and the fixture.
- Treat local StoreKit testing as insufficient evidence for production: configure and verify App Store Connect metadata and use Sandbox/review environments for storefront prices, subscription lifecycle, restore, Family Sharing, and cross-device behavior.
- For paywall or review work, test both platform presenters and the shared controller’s cancellation, persistence, cooldown, and multi-surface rules. Do not infer a rating or prompt display from an attempt record.
- For text or product-copy changes, complete all three languages, run `Scripts/check-zh-localization.sh`, and run `AppLanguageTests` where applicable.
- For widget/deep-link changes, test bounded payload construction, restoration/duplicate handling, and route validation. For marketing changes, run `npm run build` in `LandingPage/`, preserve real device chrome, and recapture affected locale/platform combinations.
