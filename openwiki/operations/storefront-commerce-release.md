---
type: storefront-release-operations
title: Storefront and Commerce Release
description: Release checklist for the local StoreKit product fixture, RevenueCat entitlement and paywall configuration, cross-platform access refresh, and Sandbox validation.
tags: [app-store, storekit, revenuecat, commerce, subscriptions, localization, release]
sources:
  - id: openwiki-source-7a80b79a6fb3618cbfab08a2
    resource: repo://.github/workflows/build.yml
  - id: openwiki-source-ed77bc20b48d193bace3dde6
    resource: repo://.gitmodules
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-1ec9ab80a210ef2b285346a3
    resource: repo://Configuration/README.md
  - id: openwiki-source-5d141331a3c311047e5071f9
    resource: repo://Configuration/Services.xcconfig
  - id: openwiki-source-cf46ee9dde9e2af41c84b62f
    resource: repo://fastlane/lib/screenshots.rb
  - id: openwiki-source-b2f57db7a90dcc30dd3886da
    resource: repo://Frameworks/TermindApplication/FeatureModels/AppReviewController.swift
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
  - id: openwiki-source-11cfe0665e72a8d0495fdce1
    resource: repo://Frameworks/TermindPresentation/AppReviewInvitationView.swift
  - id: openwiki-source-536cfba78a3618b317d33d47
    resource: repo://Frameworks/TermindPresentation/ProPaywallState.swift
  - id: openwiki-source-eae5d91412d0e2847dacd5b6
    resource: repo://FrameworkTests/AppReviewControllerTests.swift
  - id: openwiki-source-d4dc435e4e9f6262c9e07564
    resource: repo://FrameworkTests/ProPaywallStateTests.swift
  - id: openwiki-source-35e54ff3f3ad9f3931b11be7
    resource: repo://FrameworkTests/RevenueCatCommerceTests.swift
  - id: openwiki-source-312068bbb0c002500116ba72
    resource: repo://Scripts/bump-version.py
  - id: openwiki-source-ba52e849ccbc71f7247c983a
    resource: repo://Scripts/ci/apple-build.py
  - id: openwiki-source-cc4c1f81aab18928b247e547
    resource: repo://Scripts/ci/archive-apple.sh
  - id: openwiki-source-af3f04baa8e4f13f98b7d6c7
    resource: repo://Scripts/Tests/test_apple_build.py
  - id: openwiki-source-9fc915d39c61b81a60426eb3
    resource: repo://StoreKit/Termind.storekit
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-0ffab0ae6452f870ce4a0efe
    resource: repo://TFI/Features/Commerce/MobileProView.swift
  - id: openwiki-source-4bb1006b8fba7cd74268940b
    resource: repo://TFI/Features/Settings/MobileMCPSettings.swift
  - id: openwiki-source-4f0f9c14c0bea850182fe19b
    resource: repo://TFI/Info.plist
  - id: openwiki-source-25a2df896b93f410289e8512
    resource: repo://TFI/TFI.entitlements
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-b8fca76c89564e16eccfbb53
    resource: repo://TFM/App/MCPServerController.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-766dc23f16ac26a41a5b5c22
    resource: repo://TFM/Features/Commerce/ProPaywallView.swift
  - id: openwiki-source-883d6a1cb850ad090f77e1e2
    resource: repo://TFM/Features/Settings/MCPServerSettings.swift
  - id: openwiki-source-505082ab39bbdf0e8488bf01
    resource: repo://TFM/Info.plist
  - id: openwiki-source-f5ab2303a67ae18cbe2f59f2
    resource: repo://TFM/TFM.entitlements
generated: { by: "openwiki/0.7.0", at: "2026-10-25T22:25:01.745Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-25T22:25:01.745Z
---

# Storefront and Commerce Release

**Three separate authorities:** `StoreKit/Termind.storekit` is a local catalog fixture, App Store Connect defines the live Apple products and introductory offer, and RevenueCat supplies the configured `termind_pro` entitlement and remotely configured paywall. A fixture product or signed CloudKit capability does not grant Pro. Check the RevenueCat dashboard, Apple storefront and native app together before shipping; do not treat local test prices, screenshots or UI strings as production purchase evidence. See [Commerce, localization and product surfaces](../concepts/commerce-localization-and-product-surfaces.md) for the broader gate and copy ownership map.

## Product and configuration checks

| Local fixture field | Annual | Lifetime |
| --- | --- | --- |
| Product ID | `com.akinokaede.termind.pro.annual` | `com.akinokaede.termind.pro` |
| Reference / English name | Termind Pro Annual | Termind Pro Lifetime |
| US fixture price and type | 3.99, yearly auto-renewable | 9.99, non-consumable |
| Simplified Chinese name | Termind Pro 年度订阅 | Pro终身版 |
| Traditional Chinese name | Termind Pro 年度訂閱 | Pro終身版 |
| English description | Annual access to unlimited hosts & iCloud sync. | Lifetime access to unlimited hosts & iCloud sync. |
| Simplified Chinese description | 年度订阅，畅享无限主机与iCloud同步。 | 终身畅享无限主机与iCloud同步。 |
| Traditional Chinese description | 年度訂閱，享有無限主機與iCloud同步。 | 終身享有無限主機與iCloud同步。 |

The fixture marks both products Family Shareable and puts annual in the `Termind Pro` subscription group with one two-week free introductory period. The former local commerce catalog/trial test files are removed; the fixture is for manual development. Local unit tests do not prove live offerings, eligibility or purchases. Validate prices by territory, group, offer eligibility (fresh versus previously used account), Family Sharing and the intended billing grace policy in App Store Connect and Sandbox separately. The local file does not specify a production grace-period length.

Both targets obtain `TermindRevenueCatAPIKey` and `TermindRevenueCatEntitlementID` from their `Info.plist` build substitutions. Project-level Debug and Release configurations use `Configuration/Services.xcconfig`; the app targets inherit these service settings without target-level overrides. The tracked defaults leave `REVENUECAT_API_KEY` empty and set `REVENUECAT_ENTITLEMENT_ID = termind_pro`, with an optional `Services.local.xcconfig` include. To enable your own service, copy `Configuration/Services.local.xcconfig.example` to the ignored local file and supply your public Apple SDK key and matching entitlement, or provision CI build-setting overrides. An unconfigured local checkout is supported, but **does not bypass Pro checks**. Firebase configuration is separately optional and Crashlytics symbol upload defaults to disabled. Follow [Local service configuration](../../Configuration/README.md); do not publish local configuration files or logs containing their values. Check **resolved values in the signed release build**, not only source settings: `RevenueCatConfiguration` trims whitespace, rejects missing/placeholder entitlement or invalid/private keys, and accepts `test_` keys only in DEBUG. Invalid configuration gives `.verificationFailed` and an unavailable fallback, not a StoreKit access bypass. The RevenueCat dashboard must map both Apple products to the correct entitlement, configure offerings, remote paywall variants, copy, legal links and restoration, and use the matching Apple app/store credentials. The service uses StoreKit 2, informational entitlement verification, anonymous RevenueCat IDs (not device/iCloud IDs), disabled automatic device-ID collection and the stored app language as preferred RevenueCat UI locale. Test universal Apple purchases across Mac and iOS via explicit restore; anonymous IDs may be aliased through restoration rather than being identical between devices.

Signing is a different check: the targets have distinct `TFI/TFI.entitlements` and `TFM/TFM.entitlements`. Both declare the CloudKit container, webcredentials domain and bundle-derived keychain group; Mac also has App Sandbox with device, network and selected-file permissions. Both app targets use automatic signing. Their source Debug settings select `APS_ENVIRONMENT = development` and `ICLOUD_CONTAINER_ENVIRONMENT = Development`; Release selects `production` and `Production`. The Mac Release configuration still specifies `CODE_SIGN_IDENTITY = "Apple Development"`: a configuration named Release is not evidence of a distribution-signed artifact. Check provisioning and production iCloud/push environment on signed builds, but do not read StoreKit products, introductory offers or Pro access from these capability declarations. See [CloudKit Release Readiness](cloudkit-release-readiness.md) for the separate capability and environment checks.

### Inspect the release artifact, not just the project

The checked-in native Release settings use marketing version `1.17.4` for both apps, but separate build numbers: Mac `TFM` is `112` and mobile `TFI` is `101`. The project-level `CURRENT_PROJECT_VERSION` is `75`, so it is not the app artifact's build number: the app targets override it. Project Debug/Release inherit `Services.xcconfig`, whose tracked contents do not set versions. These are source baselines, not uploaded build identifiers. The CI archive script runs `Scripts/bump-version.py "$BUILD_VERSION"` first: it sets the requested marketing version, increments the project and each app's build independently, and aligns Widgets with TFI. Local includes and invocation overrides still require artifact inspection, and export permits Xcode to manage the final build number. Match the processed build in App Store Connect to the intended platform and version rather than copying a project value. See the [mobile Release settings](../../Termind.xcodeproj/project.pbxproj#L2340-L2380), [project configurations](../../Termind.xcodeproj/project.pbxproj#L2456-L2587), and [Mac Release settings](../../Termind.xcodeproj/project.pbxproj#L2626-L2667).

For each platform, privately inspect the resolved configuration for the actual archive invocation and the app that will be delivered (again after export if signing changes). Do not dump build settings or publish raw logs containing service configuration; the CI archive script deliberately avoids both. Retain sanitized verification results rather than credential-bearing output. Check:

- Bundled `TermindRevenueCatAPIKey` and `TermindRevenueCatEntitlementID`: no unresolved `$(...)` macros, the intended public Apple SDK key and `termind_pro`, and no DEBUG-only `test_` key. The `appl_` key is a client configuration identifier, **not a private RevenueCat management credential**; do not place private dashboard/API or Apple signing credentials in these substitutions.
- Signed identity, team, bundle identifier, provisioning profile and effective entitlements: compare the actual signed values with the intended distribution channel rather than assuming automatic signing or source macros resolved as intended.
- Push and CloudKit environments, the CloudKit container and keychain group: inspect the resolved signature as well as the bundled `TermindCloudKitEnvironment`. A correct source file alone is insufficient.

For an extracted iOS app, the plist is at `Termind.app/Info.plist`; for Mac it is at `Termind.app/Contents/Info.plist`. Useful inspection commands (replace the path with the actual delivered app) are:

```sh
plutil -p /path/to/Termind.app/Info.plist
codesign -dvv /path/to/Termind.app
codesign -d --entitlements :- /path/to/Termind.app
```

Use the Mac plist path for the first command when inspecting the Mac app. Record artifact inspection separately from dashboard review and Sandbox transaction results; none of these commands validates live offerings, eligibility or storefront acceptance.

## Apple upload and release ownership

The manual [Build workflow](../../.github/workflows/build.yml) accepts a three-component `version` and `platform` (`All`, `iOS`, or `macOS`) and uses the `app-store-connect` environment. It does not cancel an in-progress release run. Its checkout explicitly skips submodules, so a successful build does not validate website assets or final screenshots.

Unlike an unconfigured local build, release preparation requires Firebase configuration, a public `appl_` RevenueCat key, the entitlement ID, signing certificates/profiles and App Store Connect authentication. [`apple-build.py`](../../Scripts/ci/apple-build.py) validates the Firebase bundle ID and required fields and rejects invalid RevenueCat settings before installing the temporary configuration. It writes the ignored service files and enables Crashlytics symbol upload. The workflow runs cleanup even after failure; do not publish the private build directory or configuration-bearing logs.

[`archive-apple.sh`](../../Scripts/ci/archive-apple.sh) selects TFI for generic iOS or TFM for generic macOS, applies the version bump, archives Release and calls `xcodebuild -exportArchive`. Export uses `method = app-store-connect`, `destination = upload`, automatic signing, Production iCloud, symbol upload and `manageAppVersionAndBuildNumber = true`. **Upload is the automation boundary, not release approval.** Check Apple processing and the final Xcode-managed build number in App Store Connect. TestFlight distribution, App Review submission and release remain manual responsibilities. Complete the commerce, Sandbox, capability and storefront checks on this page before selecting the intended build for review and release.

```mermaid
flowchart TD
    Dispatch["Manual Build dispatch: version and platform"] --> Prepare["Validate services and prepare signing"]
    Prepare --> Archive["Bump versions and archive Release"]
    Archive --> Upload["Export and upload with Xcode-managed build number"]
    Upload --> Processing["Check Apple processing and final build number"]
    Processing --> Testing["Manual TestFlight distribution and validation"]
    Testing --> Review["Manual App Review submission"]
    Review --> Release["Manual release after approval"]
```

The flow separates automated archive/upload from the operator's processing, testing, review and release decisions; upload success does not prove any downstream approval.

For focused pipeline checks, run `python3 -m unittest discover -s Scripts/Tests -p 'test_apple_build.py'`. The suite checks platform/version validation, service configuration rejection and upload export options, including Xcode-managed build numbering and Production iCloud. These are local contract tests, not evidence of a successful Apple upload or Sandbox purchase.

## Access and refresh lifecycle

`ProAccessController.live()` builds a `RevenueCatProPurchaseService` if bundled configuration is valid. The observable main-actor controller is the gate: `canUse` tests current `hasProAccess`, while a denied `require(feature)` presents the paywall. The current `ProFeature` set is Vault sync, unlimited Hosts, Tailscale and optional SFTP/port-forwarding multi-connection acceleration. Ordinary Workspace composition and SSH terminal uploads are free when their normal connection and destination gates pass. Tests and screenshot setups can create `.unrestrictedForTesting`; production must use RevenueCat status. Do not treat product descriptions as the complete paid-feature contract: `.assistant`, `.remoteMCP`, `.mcpServer` and `.unlimitedMetrics` are not current Pro feature cases.

Host access is a separate admission check: free access permits three ordinary Hosts, selected deterministically by creation date then UUID; Pro unlocks all ordinary Hosts. Additional saved Hosts are locked rather than deleted. Over-limit operations during `.loading` or `.verificationFailed` report unresolved/failed verification rather than treating that state as a resolved free account. Check purchase, expiry and verification failure with more than three Hosts, not just with an empty library. See [Commerce, localization and product surfaces](../concepts/commerce-localization-and-product-surfaces.md) for the detailed Host policy.

The Mac built-in MCP server is constructed without a Pro predicate and its settings toggle calls `setEnabled` directly. Mobile remote MCP Add and Import actions likewise have no `.remoteMCP` gate. This does not establish a built-in server on mobile: validate remote-client messaging separately from Mac server availability. [Source: `ProAccessTypes.swift`](../../Frameworks/TermindDomain/Commerce/ProAccessTypes.swift), [Host policy](../../Frameworks/TermindDomain/Hosts/HostAccessPolicy.swift), [mobile MCP settings](../../TFI/Features/Settings/MobileMCPSettings.swift).

For Mac release verification, inspect the **composition root**, not the `AppModel` initializer default: `AppModel` defaults to `.unrestrictedForTesting()`, but `TermindApp` explicitly injects `.live()` for normal launches and `.unrestrictedForTesting()` when running tests. The DEBUG screenshot-demo branch also explicitly injects unrestricted access and returns early. Neither a screenshot nor a directly constructed default `AppModel` demonstrates production entitlement enforcement.

On mobile, `TermindIOSApp` selects `MobileAppDependencies.live()` for normal launches and `.testing()` when `XCTestConfigurationFilePath` is present. Neither dependency factory explicitly injects `proAccess`: `.live()` supplies `hosts: nil` and `inMemory: false`, while `.testing()` sets `inMemory: true`. `MobileAppModel` honors an explicitly injected `proAccess` first; only when it is absent does the model choose unrestricted access for in-memory or supplied-host fixtures and `.live()` otherwise. Thus the production entitlement controller is selected by the model's fallback, not by an explicit controller assignment in the live factory. Validate the normal launch path on iPhone and iPad, not just a fixture-created model. `MobileRootView` binds the paywall sheet directly to `app.pro.isPaywallPresented`; its URL routing is unrelated to purchase authorization.

Mac entitlement changes also reconcile runtime services: `accessDidChange` updates Host admission, sync, Tailscale, Metrics and effective SFTP/port-forwarding connection preferences without requiring a visible settings surface. `RootView` also observes status changes to reconcile Host admission and sync; this no longer reconciles a Pro-gated built-in MCP server. SFTP integration tests verify that gaining access restores the saved concurrency strategy and losing access uses the free effective strategy without rewriting saved preferences or opening a paywall. Include access gain/loss in release checks, not just initial paywall presentation.

```mermaid
flowchart TD
    App["Live ProAccessController"] --> Config{"Valid bundled RevenueCat config"}
    Config -->|no| Failed["Verification failed"]
    Config -->|yes| Service["RevenueCat service"]
    Service --> Fetch["Current CustomerInfo"]
    Service --> Stream["CustomerInfo stream"]
    Fetch --> Resolve["Resolve configured entitlement"]
    Stream --> Resolve
    Resolve --> Status["Controller access status"]
    Status --> Gate["Feature gates and paywall state"]
    Status --> Timer["Future granting subscription deadline"]
    Timer --> Fetch
```

The diagram separates the RevenueCat entitlement path from the remote UI and local StoreKit fixture.

`RevenueCatEntitlementResolver` rejects failed CustomerInfo or entitlement verification and ignores unrelated entitlements and product IDs without the configured entitlement. An active entitlement without an expiration grants purchased lifetime access, including Family Sharing. An active subscription grants Pro during an unexpired trial or paid period; with a detected billing issue it grants grace only while an active grace deadline is in the future. Refund maps to revoked, an expired billing issue to billing retry and otherwise an expired period to expired. Canceling renewal leaves an unexpired subscription active. A stale cached `isActive` flag alone cannot extend access past its date; unlike the former StoreKit code, there is no post-expiry `.subscribed` fallback. Validate the actual RevenueCat ownership, trial, refund and grace responses from Sandbox before promising these transitions in storefront copy.

The service requests `customerInfo(fetchPolicy: .fetchCurrent)` rather than relying on SDK cache for deadlines, resolves cached CustomerInfo if the request fails, and throws when no cache exists. It listens to `customerInfoStream`; the controller coalesces concurrent refreshes and gives newer stream updates priority over older in-flight responses. Initial failure becomes `.verificationFailed`, while a later failed refresh retains an established status; therefore an offline refresh is **not** proof of a newly processed revocation. On a non-test store, if a valid initial status lacks access, the service attempts `syncPurchases()` once per anonymous user to import older Apple purchases and records successful migration in defaults; this is not the remote paywall's user-initiated Restore action. An applied granting subscription with future `expiresAt` replaces a cancellable deadline task; wakeup calls `refresh()` rather than revoking locally. App activation on Mac and active scene transition on iOS also request refresh. Check an already-open app through trial expiry, renewal, cancellation and grace expiry in Sandbox, including offline/reconnect behavior.

## Remote paywall contract and review

Mac `ProPaywallView` and iOS `MobileProView` embed **RevenueCatUI `PaywallView`**, not a shared native `ProPaywallContent` or `ProOfferPresentation`. While access is `.loading`, each shows a localized progress view; if RevenueCat is unconfigured, it shows an unavailable message and close action. Otherwise each passes `ProPaywallState` into remote paywall variables: `pro` (access), `manage` (purchaser-owned subscription only), `family`, `dated`, locale-formatted `date` (empty if unknown), and the protocol `state` (`trial`, `renewing`, `ending`, `active`, `grace`, `retry`, `expired`, `revoked`, `lifetime`, `free`, `unverified`, etc.). These codes are dashboard rules, **not localized visible strings**. A canceled-but-unexpired subscription can have `ending` while retaining `pro`; a family-shared subscription or lifetime purchase has no manage flag. The dashboard—not the app's obsolete native formatters—owns tiles, plan selection, price/trial/renewal disclosure, feature rows, buttons, legal links, accessibility layout and localized copy. Do not infer mobile/Mac-specific MCP messaging, a Metrics limit callout, a hard-coded 14-day label or reload-prices UI from `AppStrings.Pro` entries or the fixture. Review the actual dashboard variants in English, zh-Hans and zh-Hant on both platforms, especially that mobile does not promise the built-in Mac MCP server and that the trial claim appears only for eligible accounts.

```mermaid
sequenceDiagram
    participant Feature as Pro feature caller
    participant Gate as ProAccessController
    participant Native as Native sheet
    participant UI as RevenueCatUI PaywallView
    participant RC as RevenueCat service
    Feature->>Gate: require feature
    Gate->>Native: present if denied
    Native->>UI: render with status variables
    UI->>Gate: check access before purchase
    Gate-->>UI: proceed only without Pro access
    UI->>RC: SDK purchase or restore
    RC-->>Gate: CustomerInfo update
    UI->>Gate: operation completed
    Gate->>RC: refresh current status
    Gate-->>Native: updated account variant
```

Purchase and restore callbacks refresh the controller's entitlement status while the native sheet can remain open on the account variant.

Both wrappers refuse purchase initiation if access already exists. They do not maintain an app-owned processing flag or register start, cancellation, failure or disappearance callbacks to clear one; transaction UI is delegated to RevenueCatUI. Completion calls `completePaywallOperation()`, which only awaits entitlement refresh without closing the sheet. The first RevenueCat dismissal request after purchase is suppressed so the account variant remains visible; a subsequent dismissal can close it. Mac chooses one owner window for the sheet; iOS presents it from `MobileRootView`. Confirm purchase/restore failures and recovery in real UI rather than assuming controller unit tests exercise SDK purchases.

## Language changes are presentation changes

On Mac, the language picker persists `AppLanguage` and displays a relaunch notice when it differs from the launch language. `AppLanguage.store` updates the app setting and Apple's `AppleLanguages` override; Follow System removes that override. RevenueCat reads the stored locale when its SDK is first configured, while the native paywall formats its `date` variable with the view's locale. Relaunch before reviewing a changed language; do not assume changing the setting reconfigures an already-running RevenueCat SDK.

This path does **not** change entitlement resolution, purchase authorization or restore callbacks, and is not a way to reset introductory-offer eligibility. Keep language/copy review separate from account eligibility and transaction validation: verify the actual remote paywall after relaunch, then use the appropriate Sandbox accounts for purchases and restores. The manual StoreKit fixture's English and Chinese strings do not prove RevenueCat dashboard locale coverage.

## App Store review invitation is not purchase evidence

The user-facing review link opens `https://apps.apple.com/app/id6805856690?action=write-review` through SwiftUI `openURL`. `AppReviewController` records `.openedReview` only when the URL-open completion is accepted; this records **intent to review**, never a submitted rating, successful purchase or Apple review approval. A rejected open leaves the invitation available. Decline and accepted-open responses persist in device-local defaults and suppress later invitations; they are not synced commerce or entitlement state.

Normal invitation eligibility requires an enabled controller, no prior response, at least one host and seven elapsed days since first use. `AppReviewInvitationVisit` captures eligibility on page entry so time passing or a newly synced host cannot insert it mid-visit; filtering or losing the last host hides it without consuming it. Developer preview bypasses eligibility but neither opens the external URL nor changes the real saved response. `FrameworkTests/AppReviewControllerTests.swift` covers these gates, persistence, rejected opens, shared-window suppression and preview isolation. Release review should separately check the actual destination and user-initiated open on each platform; neither preview nor a successful URL handoff verifies App Store transaction delivery.

## Release validation

1. Reconcile product IDs, types, group, Family Sharing, introductory eligibility and grace settings in App Store Connect **and** entitlement-to-product mapping, offering/paywall rules and localized disclosure in RevenueCat. Test new versus used-offer accounts, trial-to-paid renewal, cancellation through expiry, billing retry with and without grace, refunds, Family Sharing and lifetime restoration across Mac, iPhone and iPad. Record Sandbox results separately from the fixture and production configuration review.
2. Run the default shared/macOS tests as described in [Build, Test, and Release](build-test-and-release.md). `FrameworkTests/RevenueCatCommerceTests.swift` tests key validation, configured-entitlement resolution, expiration/grace/refund/verification, completion, stream updates, refresh races and failure recovery using decoded CustomerInfo and fake services. `FrameworkTests/ProPaywallStateTests.swift` tests dashboard variable mapping; `TFMTests/ProAccessTests.swift` tests gate semantics. There is no current `ProOfferPresentationTests`, `ProPaywallPresentationTests`, `TFMTests/ProPaywallRenderingTests` or `TFITests/ProPaywallRenderingTests` to validate remote paywall rendering. Check both native remote paywalls visually with live Sandbox metadata and dynamic type; unit and fixture tests do not cover a real SDK purchase, restore or the dashboard layout.
3. Check final localized **storefront imagery** separately from the paywall. The parent screenshot runner supports and defaults to all seven locale keys: `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `de`, and `fr`; `locales` options or `TERMIND_MAC_SCREENSHOT_LOCALES` / `TERMIND_SCREENSHOT_LOCALES` can narrow the selection. It sets test language, region and Apple locale for each capture. This is capture-tool coverage, not proof of localized remote paywalls or final exported boards. Initialize the independent website/assets checkout with `git submodule update --init com.akinokaede.termind`, then read its current asset documentation and delivery contract and inspect the actual localized files. The submodule is declared in [`.gitmodules`](../../.gitmodules), and the parent runner requires an initialized checkout with an `assets` directory. Its asset README and final exports were unavailable for this inspection, so no current delivery-contract contents or final inventory are established here. After initialization, read the checkout's current documentation and distinguish capture inputs, any framing intermediates and final artwork during review. Establish the release inventory from the actual exports; verify locale coverage, filenames, canvas sizes, opacity and embedded RGB/sRGB profiles against its current delivery contract and intended uploads. Review language, composition, platform promises and offer claims against the native app and current App Store requirements, then confirm acceptance for the intended App Store upload slots. Parent screenshot-tool dimensions describe native capture inputs—not proof of final board dimensions or upload acceptance—and captures/device frames are not final storefront artwork. See [Marketing Assets and App Icons](marketing-assets-and-app-icons.md) for checkout inspection, capture/framing, composition/export review and SSH-first publication; do not substitute a historical inventory for that release review.
4. Keep evidence separate: the StoreKit fixture verifies catalog *shape*; resolver tests verify local policy; signed-build checks verify credentials/capabilities; Sandbox and dashboard checks verify actual product delivery, eligibility, purchase, restore, legal copy, accessibility and Family Sharing. Coordinate changed app strings, website claims and imagery with remote paywall copy without silently changing product IDs or entitlement mapping.
