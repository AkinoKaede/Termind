---
type: product-surface-concept
title: Commerce, Localization and Product Surfaces
description: Explains RevenueCat-derived Pro access and remote paywalls, native language and copy ownership, and the separate app, widget, screenshot, and public-site product surfaces.
tags: [commerce, revenuecat, localization, product-surfaces, marketing, widgets]
sources:
  - id: openwiki-source-ed77bc20b48d193bace3dde6
    resource: repo://.gitmodules
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-a8a9aade8fbc89d5829a491e
    resource: repo://Frameworks/Resources/Localizable.xcstrings
  - id: openwiki-source-a51ca858a040a90d4ab9c1c4
    resource: repo://Frameworks/TermindApplication/AppLanguage.swift
  - id: openwiki-source-b2f57db7a90dcc30dd3886da
    resource: repo://Frameworks/TermindApplication/FeatureModels/AppReviewController.swift
  - id: openwiki-source-04b071ada5b9e8d7b65a1b7a
    resource: repo://Frameworks/TermindApplication/FeatureModels/SnippetTimestamp.swift
  - id: openwiki-source-ca49232858afa421bf33a03b
    resource: repo://Frameworks/TermindApplication/Metrics/ServerMetricsModel.swift
  - id: openwiki-source-b37c974aaea12bd08606d67d
    resource: repo://Frameworks/TermindDomain/Commerce/ProAccessTypes.swift
  - id: openwiki-source-3aa42bdd0f8eaf866f06599f
    resource: repo://Frameworks/TermindInfrastructure/Commerce/ProAccessController.swift
  - id: openwiki-source-f0aa3596750ed8bd3ffd8c9e
    resource: repo://Frameworks/TermindInfrastructure/Commerce/RevenueCatConfiguration.swift
  - id: openwiki-source-38ed84f3c15242480046f900
    resource: repo://Frameworks/TermindInfrastructure/Commerce/RevenueCatEntitlementResolver.swift
  - id: openwiki-source-82f1da82c84bec6e60959357
    resource: repo://Frameworks/TermindInfrastructure/Commerce/RevenueCatProPurchaseService.swift
  - id: openwiki-source-4706711c42fe2431044b1e84
    resource: repo://Frameworks/TermindPresentation/OperationConfirmation.swift
  - id: openwiki-source-536cfba78a3618b317d33d47
    resource: repo://Frameworks/TermindPresentation/ProPaywallState.swift
  - id: openwiki-source-9eb0eec8ab67d2032ec11b01
    resource: repo://Frameworks/TermindPresentation/SnippetCardContent.swift
  - id: openwiki-source-2d3fd78e62a89dd2c0b202e6
    resource: repo://Frameworks/TermindPresentation/Strings/AppStrings.swift
  - id: openwiki-source-667f8dcadd921c1910c5026c
    resource: repo://Frameworks/TermindPresentation/Strings/LocalizedStringResource%2BPresentation.swift
  - id: openwiki-source-a3debd0d113ee290e9ff3df7
    resource: repo://Frameworks/TermindPresentation/Strings/Navigation.swift
  - id: openwiki-source-f0eb100f79cea6b455207748
    resource: repo://Frameworks/TermindPresentation/Strings/Presentation.swift
  - id: openwiki-source-eae5d91412d0e2847dacd5b6
    resource: repo://FrameworkTests/AppReviewControllerTests.swift
  - id: openwiki-source-d4dc435e4e9f6262c9e07564
    resource: repo://FrameworkTests/ProPaywallStateTests.swift
  - id: openwiki-source-35e54ff3f3ad9f3931b11be7
    resource: repo://FrameworkTests/RevenueCatCommerceTests.swift
  - id: openwiki-source-7d8d2d50a9c530a1decb39f3
    resource: repo://Scripts/check-appstrings.swift
  - id: openwiki-source-c6328be86432b33a68051c73
    resource: repo://Scripts/check-cjk-localization.py
  - id: openwiki-source-de562e98d49cbf6502c23c13
    resource: repo://Scripts/normalize-string-catalogs.py
  - id: openwiki-source-60d4159ef162d09de4f4b469
    resource: repo://Scripts/run-screenshot-demo.sh
  - id: openwiki-source-9fc915d39c61b81a60426eb3
    resource: repo://StoreKit/Termind.storekit
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-c8d832474c03f5ebad7b0578
    resource: repo://TFI/App/MobileRootView.swift
  - id: openwiki-source-e43a0da5ab77c2fc3554244d
    resource: repo://TFI/App/MobileSceneModel.swift
  - id: openwiki-source-13f2deff6904678799b19444
    resource: repo://TFI/Application/Metrics/MobileMetricsModel.swift
  - id: openwiki-source-0ffab0ae6452f870ce4a0efe
    resource: repo://TFI/Features/Commerce/MobileProView.swift
  - id: openwiki-source-ad662f2a7016a994d8522bf2
    resource: repo://TFI/Features/KnownHosts/MobileKnownHostsView.swift
  - id: openwiki-source-a053f8c3524e81f98b0b0938
    resource: repo://TFI/Features/Metrics/MobileMetricsView.swift
  - id: openwiki-source-db402cad9d68dd8e66bdd7ee
    resource: repo://TFI/Features/Snippets/MobileSnippetsView.swift
  - id: openwiki-source-3f37062f55fb57a9f2e97f35
    resource: repo://TFI/Features/Vault/MobileVaultView.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-637644793f7e37cc057eb973
    resource: repo://TFI/Platform/MobileLiveActivityController.swift
  - id: openwiki-source-c32ed562101f11a0c3c89663
    resource: repo://TFITests/MobileCardTests.swift
  - id: openwiki-source-205304536d13b39bf2e7e666
    resource: repo://TFITests/Screenshots/MobileCardRenderingTests.swift
  - id: openwiki-source-d1ffd558b3360478aa85b5af
    resource: repo://TFIWidgets/WorkspaceLiveActivity.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-2b65afedbf9d80b1d387f50a
    resource: repo://TFM/App/ScreenshotDemo.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-766dc23f16ac26a41a5b5c22
    resource: repo://TFM/Features/Commerce/ProPaywallView.swift
  - id: openwiki-source-bf08592e56aa88a7189a7fb5
    resource: repo://TFM/Features/KnownHosts/KnownHostsPageView.swift
  - id: openwiki-source-793d7861000adc19f0c3df01
    resource: repo://TFMTests/AppLanguageTests.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-dc392b9979d99f5026bdeadf
    resource: repo://TFMTests/PresentationCopyTests.swift
  - id: openwiki-source-0f8d0f9d08d6674698dd054c
    resource: repo://WorkspaceActivitySupport/WorkspaceActivityAttributes.swift
generated: { by: "openwiki/0.7.0", at: "2026-10-09T00:05:26.272Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-09T00:05:26.272Z
---

## Commerce ownership and configuration

`ProAccessController` is the shared, observable main-actor access gate. Both production app targets construct it with `live()`; test, in-memory and screenshot setups can use unrestricted test access. Its `ProPurchaseService` is a narrow status-and-update interface, not a StoreKit purchasing API. `live()` builds `RevenueCatProPurchaseService` from the bundled `TermindRevenueCatAPIKey` and `TermindRevenueCatEntitlementID`; an absent or invalid configuration yields `.verificationFailed`, **not** free access through a second StoreKit observer. The configuration trims values, rejects unresolved placeholders and private keys, allows `test_` keys only in DEBUG and expects a public `appl_` production key. The configured entitlement (`termind_pro` in the project settings) is the unlock key: product IDs alone do not grant access. Both apps configure RevenueCat's StoreKit 2 mode with informational entitlement verification, an anonymous app user ID, device-identifier collection disabled and a preferred UI locale from the stored app language. See [Storefront Commerce Release Checks](../operations/storefront-commerce-release.md) for production dashboard and sandbox checks.

`StoreKit/Termind.storekit` is a **local fixture**, not the live storefront or RevenueCat paywall configuration. It contains the family-shareable lifetime non-consumable `com.akinokaede.termind.pro` and yearly family-shareable subscription `com.akinokaede.termind.pro.annual`, the latter with a two-week free introductory offer and English, Simplified Chinese and Traditional Chinese product descriptions. The former `CommerceConfigurationTests` and `StoreKitTrialTests` files are removed. The fixture does **not** run the removed StoreKit entitlement/purchase integration suite or establish actual RevenueCat offerings, eligibility, price, purchase, restore or deadline behavior. Never infer a guaranteed trial or a price for every user from the fixture.

## Entitlement lifecycle and feature boundaries

The RevenueCat service consumes `customerInfoStream` (latest-buffered), and `currentStatus()` requests `customerInfo(fetchPolicy: .fetchCurrent)` to revalidate deadlines rather than trusting a still-fresh SDK cache. On a fetch failure it resolves cached customer info if available; without cache it throws. The controller coalesces concurrent refreshes; a newer streamed update cancels and supersedes an older in-flight refresh so a stale response cannot undo a grant or revocation. An initial failure becomes `.verificationFailed`; a later failure retains the last established status. On a non-test store, if an initial valid status does not grant access, the service attempts `syncPurchases()` once per anonymous app user ID (recording successful migration in defaults) to import pre-integration Apple purchases. This is distinct from an app-managed Restore Purchase button.

```mermaid
flowchart TD
    Start["Live controller"] --> Config{"Valid RevenueCat config"}
    Config -->|no| Unverified["Verification failed"]
    Config -->|yes| Fetch["Fetch current CustomerInfo"]
    Stream["CustomerInfo stream update"] --> Resolve["Resolve configured entitlement"]
    Fetch --> Resolve
    Resolve --> Verify{"Verification failed"}
    Verify -->|yes| Unverified
    Verify -->|no| Present{"Configured entitlement present"}
    Present -->|no| Free["Free access"]
    Present -->|yes| Lifetime{"Active with no expiration"}
    Lifetime -->|yes| Pro["Lifetime Pro"]
    Lifetime -->|no| Phase["Classify subscription phase and deadline"]
    Phase -->|trial subscribed grace| Pro
    Phase -->|retry expired revoked| Free
    Pro --> Timer["Schedule refresh at future expiry"]
    Timer --> Fetch
```

This is the access-resolution and refresh path, not a guarantee that a remote paywall offers a particular plan.

`RevenueCatEntitlementResolver` rejects failed CustomerInfo or entitlement verification and ignores entitlements other than the configured ID. An active entitlement without an expiration maps to lifetime purchased access (including family-shared ownership); an inactive one is free. A subscription grants access for an active trial or subscription before its deadline, and for an active billing-issue grace period before the **grace** deadline. Refund maps to revoked; after the deadline a billing issue maps to billing retry and otherwise to expiry. Cancellation disables renewal but does not itself withdraw access before expiration. Unlike the previous StoreKit `.subscribed` fallback, a cached `isActive` flag cannot extend access beyond a past deadline. `apply` cancels its prior expiration timer and schedules a re-fetch at a future granting subscription deadline; no timer is installed without a future deadline. iOS scene activation and macOS app activation also refresh access. A refresh failure without cache can retain an established controller status, so neither a timer nor an offline test proves a server-side revocation was observed.

`ProFeature` enumerates Tailscale, Assistant, remote MCP, the built-in MCP server, Vault sync, unlimited Metrics, SFTP multi-connection acceleration and port-forwarding multi-connection acceleration. `canUse` reflects the current entitlement and `require` returns false and presents the shared paywall when denied; it does **not** record a requested feature. The basic remote-workspace experience remains free. Protected callers gate Tailscale node access, Assistant execution, remote MCP operations, built-in macOS MCP availability, iCloud sync, monitoring beyond three free cards and the optional multi-connection acceleration settings. SSH terminal uploads remain available without Pro when the session and destination are ready. The mobile Metrics picker passes current access to `MobileMetricsModel.replaceHosts`; on failure it reports the core storage error, otherwise presents Pro. The shared Metrics model preserves choices outside the edited set, counts net additions and persists a replacement atomically; desktop supplies a live card limit and calls `require(.unlimitedMetrics)` on rejection. Losing access pauses Vault, connection-history, device, Metrics and Settings sync rather than deleting local data; macOS also suspends an enabled built-in MCP server. Mobile synchronization additionally requires an active foreground scene. `RootView` reconciles macOS status changes; `MobileRootView` reconciles mobile access changes and scene activity.

## Paywall presentation and copy boundary

The native wrappers present **RevenueCatUI `PaywallView`**, not the removed `ProPaywallContent`, `ProPaywallPresentation` or `ProOfferPresentation`. macOS elects one main-window sheet owner through `ProPaywallPresenter`; iOS uses a `MobileRootView` sheet. Both show a localized loading indicator until the initial access status resolves and a localized unavailable/close fallback if RevenueCat cannot be configured. With a service, both pass `ProPaywallState` custom variables to the remote paywall: `pro`, `manage`, `state`, `family`, `dated` and a locale-formatted `date` (empty when unknown). `state` is a protocol value such as `trial`, `renewing`, `ending`, `active`, `grace`, `retry`, `expired`, `revoked`, `lifetime`, `free` or `unverified`, **not** app-visible copy. `manage` is true for purchaser-owned subscriptions, not family-shared subscriptions or lifetime. Renewal cancellation yields `ending` while access can still be active; the remote dashboard owns the visible plan tiles, terms, trial and legal links. Do not claim a locally constructed annual picker, eligibility label, Metrics explanation or platform-specific MCP list. Prices and trial disclosures must be checked in RevenueCat and the storefront, not inferred from obsolete local formatting tests.

```mermaid
sequenceDiagram
    participant Gate as Feature caller
    participant Controller as ProAccessController
    participant Native as Native sheet
    participant UI as RevenueCatUI PaywallView
    participant Service as RevenueCat service
    Gate->>Controller: require feature
    Controller->>Native: present if denied
    Native->>UI: show with status variables
    UI->>Controller: operation started
    UI->>Service: purchase or restore via SDK
    Service-->>Controller: CustomerInfo update
    UI->>Controller: operation completed
    Controller->>Service: refresh current status
    Controller-->>Native: updated access and processing
```

The native sheet delegates purchase and restore operations to RevenueCatUI and refreshes controller access on completion.

The platform views observe purchase/restore start, completion, cancellation and failure to update `isProcessing`; purchase initiation is refused if access already exists. Completion refreshes access but **does not close** the paywall: after purchase the first SDK dismissal request is ignored so the account variant can be displayed; subsequent dismissal or the close control dismisses it. Disappearing cancels the processing indicator. `ProPaywallStateTests` covers mapping of subscription phases, ownership, missing date and failed verification; `RevenueCatCommerceTests` covers remote-completion behavior, streamed grants and revocations, racing/coalesced refreshes, deadline resolution, configuration rejection and recovery from fetch errors. The old `ProOfferPresentationTests` and `ProPaywallPresentationTests` are absent. A purchase, Restore Purchase or remote layout is not integration-tested by these unit tests.

## Review and app localization

`AppReviewController` budgets StoreKit review *attempts*, not prompt presentations or ratings: after an active workspace-to-review-page transition it requires seven days since first use, three active local dates, five foreground workspace minutes, no request in the current version and a 120-day cooldown. It waits three seconds and records the attempt before calling the platform request API; navigation, focus/surface changes and blocked commerce or modal UI cancel a pending invitation. The explicit review link records an attempt as well. XCTest disables the live invitation policy.

App UI copy, including platform-specific strings and the native paywall **fallback** text, belongs to semantic `LocalizedStringResource` definitions in `Frameworks/TermindPresentation/Strings` and the shared manual `Frameworks/Resources/Localizable.xcstrings`; `InfoPlist.xcstrings` owns bundle metadata. Keep diagnostic codes, protocol values like remote paywall `state`, identifiers and user-authored content outside translated UI copy. RevenueCat's dashboard paywall text and StoreKit product metadata are **separate** copy owners. The app catalogs must have finished `zh-Hans`, `zh-Hant` and `ja` units for changed English keys. `Scripts/normalize-string-catalogs.py --write` canonicalizes catalog format and manual extraction without deleting stale keys or changing translations and refuses duplicate JSON keys before writing; `Scripts/check-cjk-localization.py` checks both app catalogs by default for normalization, valid JSON, Chinese/Japanese completion, positional format arguments, other-only plural shape and locale-specific spacing. The separate AgentKit runtime catalog needs its own localization build step; native catalog checks do not establish website copy correctness. `Scripts/check-appstrings.sh` detects selected app-local UI literals via SwiftSyntax and `ArchitectureBoundaryTests` guards the shared copy owner, but neither proves all UI text is localized.

`AppLanguage` writes an explicit `en`, `zh-Hans`, `zh-Hant` or `ja` choice to `AppleLanguages`, clears that override for Follow System, migrates legacy Simplified Chinese tags and leaves unsupported preferences following the system. `AppLocalization` resolves imperative copy from the appropriate main-bundle localization, including regional Traditional Chinese. Resolve resources at display time, rather than caching translated strings across language changes; use the resource directly with SwiftUI APIs that accept it, especially `confirmationDialog`, and `swiftUIKey` only where `LocalizedStringKey` is required. Mobile `operationConfirmation` resolves resources against the view locale before passing verbatim strings to either an anchored SwiftUI confirmation or an injected centered UIKit renderer; an explicit Cancel action remains visible. `PresentationCopyTests` checks menu, count, accessibility and bridge resolution; current `AppLanguageTests` tests preference migration, regional catalog lookup, assistant/security-token terminology, forwarding placeholder order and selected plural resources. **It no longer tests explicit-language Pro offer copy.** Full catalog completion is the Python check, not these tests.

Ordinary product labels illustrate the split: iOS Vault search opens Snippets and Known Hosts, whose pages distinguish an empty collection from empty search results. Known Hosts offers add/edit/copy-fingerprint/delete and an editor title that changes with the entry; the macOS empty state additionally offers import or manual add and deletion warns that trust will need verifying on the next connection, with count-sensitive confirmation. Snippets has new snippet/package/subpackage actions and a keep-or-remove-snippets package deletion choice. Shared `SnippetCardContent` supplies colored icons, valid SSH-target counts, risk chips and relative timestamps to both apps, while each owns the surrounding surface and actions. `SnippetTimestamp` supplies a stable local fallback for legacy baseline dates. Card timestamps use the view locale; hostnames, fingerprints, paths and scripts remain user content. `MobileCardTests` checks add/edit titles; opt-in `MobileCardRenderingTests` mounts real views in three app languages with light/dark and selected large-type captures. Inspect actual views as well as catalogs after UI changes.

## Other product surfaces and public disclosures

`TermindWidgets` contains a workspace Live Activity, not another workspace engine. The app serializes activity updates, restores at most one active activity, starts only after explicit workspace intent and ends it when workspaces are gone. Its payload excludes credentials and terminal output, bounds focused-first summaries to six, and routes only strict workspace-list and UUID workspace deep links. DEBUG macOS `ScreenshotDemoConfiguration` binds one validated scene to `en`, `zh-Hans`, `zh-Hant` or `ja` and isolated fixtures; mobile captures mount real views. Recapture affected scenes in all locales using actual platform UI rather than changing production logic for screenshots. See [Marketing Assets and App Icons](../operations/marketing-assets-and-app-icons.md).

### Website evidence boundary

[Repository guidelines](../../AGENTS.md) identify `com.akinokaede.termind/` as the independently maintained public website and assets submodule, with an Astro project at its root; [.gitmodules](../../.gitmodules) records its external repository. Native builds do not require that checkout. For website or asset work, initialize it with `git submodule update --init com.akinokaede.termind` and inspect the checked-out source before making claims about the site.

**The submodule directory is empty in this checkout.** This repair therefore does not verify current homepage composition, FAQ wording, promotions or redemption offers, public prices, privacy/security disclosures, locale routes or fallback behavior, browser language storage, canonical links, or the screenshot/image optimization pipeline. Previous descriptions of those surfaces are not evidence of the current public site. Native entitlement configuration and tests establish app behavior, not website promises.

Once source is available, follow the documented website workflow (`cd com.akinokaede.termind && npm ci && npm run build`) and inspect the actual routes, translations, images and disclosures. The workflow is documented in the parent repository; the submodule's build scripts and output have not been inspected here. Verify the deployed public site separately when assessing what users currently see. Do not infer website language behavior from `AppLanguage`, or legal disclosures from SDK configuration. Any privacy/EULA links and visible legal copy in the remote native paywall must also be checked in RevenueCat rather than inferred from the native wrappers.

## Focused change checklist

- Native entitlement policy and gates: update resolver, feature gates and app reconciliation together; run `RevenueCatCommerceTests`, `ProPaywallStateTests`, `ProAccessTests`, Metrics tests and platform-specific gate tests. Check live entitlement configuration and account migration separately from the local StoreKit metadata fixture. [RevenueCat configuration](../../Frameworks/TermindInfrastructure/Commerce/RevenueCatConfiguration.swift) and [service configuration](../../Frameworks/TermindInfrastructure/Commerce/RevenueCatProPurchaseService.swift) explain the native SDK boundary, not public-site promises.
- RevenueCat dashboard-owned paywalls and legal copy: inspect the remote layouts, visibility rules, translations, offer terms and legal destinations independently. Compare them with the native [paywall variable contract](../../Frameworks/TermindPresentation/ProPaywallState.swift), [mobile wrapper](../../TFI/Features/Commerce/MobileProView.swift), [desktop wrapper](../../TFM/Features/Commerce/ProPaywallView.swift) and [state tests](../../FrameworkTests/ProPaywallStateTests.swift). These tests verify status mapping, not remote wording or live purchases.
- Apple storefront metadata: verify live product availability, localized descriptions, prices, introductory-offer eligibility, Family Sharing and purchase/restore behavior in App Store Connect and Sandbox. Neither website prices nor the local fixture establish the offer a particular user receives. See [Storefront Commerce Release Checks](../operations/storefront-commerce-release.md).
- App catalogs: run `Scripts/normalize-string-catalogs.py --write` after app catalog edits, `Scripts/check-appstrings.sh`, `Scripts/check-cjk-localization.py`, `PresentationCopyTests` and `AppLanguageTests`; review actual screens separately. See [Behavioral Boundaries and Fixtures](../testing/behavioral-boundaries-and-fixtures.md).
- Independently authored website claims: obtain the website source and inspect the deployed site before comparing its FAQ, offers, prices, privacy/security disclosures and localized routes with native entitlement and sync behavior. Build and visually check the routes actually present in that checkout. Keep unavailable content explicitly unverified; native string tests and RevenueCat state tests do not validate it.
