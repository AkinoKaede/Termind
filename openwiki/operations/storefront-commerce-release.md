---
type: storefront-release-operations
title: Storefront commerce release checks
description: Release checklist for the local StoreKit product fixture, RevenueCat entitlement and paywall configuration, cross-platform access refresh, and Sandbox validation.
tags: [app-store, storekit, revenuecat, commerce, subscriptions, localization, release]
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
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
  - id: openwiki-source-536cfba78a3618b317d33d47
    resource: repo://Frameworks/TermindPresentation/ProPaywallState.swift
  - id: openwiki-source-d4dc435e4e9f6262c9e07564
    resource: repo://FrameworkTests/ProPaywallStateTests.swift
  - id: openwiki-source-35e54ff3f3ad9f3931b11be7
    resource: repo://FrameworkTests/RevenueCatCommerceTests.swift
  - id: openwiki-source-ef9b991e118d6fe8b7fbee55
    resource: repo://Marketing/AppStore/en/mac/01-three-screens.jpg
  - id: openwiki-source-3882fc675d1b99ff0f2ba4c3
    resource: repo://Marketing/AppStore/zh-hans/iphone-6.5/06-vault.jpg
  - id: openwiki-source-b130fb70b5ba4d89364e1196
    resource: repo://Marketing/AppStore/zh-hant/ipad-13/06-vault.jpg
  - id: openwiki-source-446ef49ac8edac86b5511fe5
    resource: repo://Marketing/README.md
  - id: openwiki-source-9fc915d39c61b81a60426eb3
    resource: repo://StoreKit/Termind.storekit
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-c8d832474c03f5ebad7b0578
    resource: repo://TFI/App/MobileRootView.swift
  - id: openwiki-source-0ffab0ae6452f870ce4a0efe
    resource: repo://TFI/Features/Commerce/MobileProView.swift
  - id: openwiki-source-4bb1006b8fba7cd74268940b
    resource: repo://TFI/Features/Settings/MobileMCPSettings.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-4f0f9c14c0bea850182fe19b
    resource: repo://TFI/Info.plist
  - id: openwiki-source-25a2df896b93f410289e8512
    resource: repo://TFI/TFI.entitlements
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
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
generated: { by: "openwiki/0.7.0", at: "2026-10-03T22:38:13.888Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-04T14:45:13.763Z
---

# Storefront commerce release checks

**Three separate authorities:** `StoreKit/Termind.storekit` is a local catalog fixture, App Store Connect defines the live Apple products and introductory offer, and RevenueCat supplies the configured `termind_pro` entitlement and remotely configured paywall. A fixture product or signed CloudKit capability does not grant Pro. Check the RevenueCat dashboard, Apple storefront and native app together before shipping; do not treat local test prices, screenshots or UI strings as production purchase evidence. See [Commerce, localization and product surfaces](../concepts/commerce-localization-and-product-surfaces.md) for the broader gate and copy ownership map.

## Product and configuration checks

| Local fixture field | Annual | Lifetime |
| --- | --- | --- |
| Product ID | `com.akinokaede.termind.pro.annual` | `com.akinokaede.termind.pro` |
| Reference / English name | Termind Pro Annual | Termind Pro Lifetime |
| US fixture price and type | 3.99, yearly auto-renewable | 9.99, non-consumable |
| Simplified Chinese name | Termind Pro 年度订阅 | Termind Pro 永久版 |
| Traditional Chinese name | Termind Pro 年度訂閱 | Termind Pro 永久版 |
| English description | Annual AI, MCP & iCloud sync access. | Lifetime AI, MCP & iCloud sync access. |
| Simplified Chinese description | 按年使用AI、MCP与iCloud同步功能。 | 永久使用AI、MCP与iCloud同步功能。 |
| Traditional Chinese description | 按年使用AI、MCP與iCloud同步功能。 | 永久使用AI、MCP與iCloud同步功能。 |

The fixture marks both products Family Shareable and puts annual in the `Termind Pro` subscription group with one two-week free introductory period. The former local commerce catalog/trial test files are removed; the fixture is for manual development. Local unit tests do not prove live offerings, eligibility or purchases. Validate prices by territory, group, offer eligibility (fresh versus previously used account), Family Sharing and the intended billing grace policy in App Store Connect and Sandbox separately. The local file does not specify a production grace-period length.

Both targets obtain `TermindRevenueCatAPIKey` and `TermindRevenueCatEntitlementID` from their `Info.plist` build substitutions; the project-level Debug and Release settings both specify a public `appl_` key and the `termind_pro` entitlement. Check **resolved values in the signed release build**, not only source settings: `RevenueCatConfiguration` trims whitespace, rejects missing/placeholder entitlement or invalid/private keys, and accepts `test_` keys only in DEBUG. Invalid configuration gives `.verificationFailed` and an unavailable fallback, not a StoreKit access bypass. The RevenueCat dashboard must map both Apple products to the correct entitlement, configure offerings, remote paywall variants, copy, legal links and restoration, and use the matching Apple app/store credentials. The service uses StoreKit 2, informational entitlement verification, anonymous RevenueCat IDs (not device/iCloud IDs), disabled automatic device-ID collection and the stored app language as preferred RevenueCat UI locale. Test universal Apple purchases across Mac and iOS via explicit restore; anonymous IDs may be aliased through restoration rather than being identical between devices.

Signing is a different check: the targets have distinct `TFI/TFI.entitlements` and `TFM/TFM.entitlements`. Both declare the CloudKit container, webcredentials domain and bundle-derived keychain group; Mac also has App Sandbox with device, network and selected-file permissions. Check provisioning and production iCloud/push environment on signed builds, but do not read StoreKit products, introductory offers or Pro access from these capability declarations.

## Access and refresh lifecycle

`ProAccessController.live()` builds a `RevenueCatProPurchaseService` if bundled configuration is valid. The observable main-actor controller is the gate: `canUse` tests current `hasProAccess`, while a denied `require(feature)` presents the paywall. `ProFeature` covers Tailscale, Assistant, remote MCP, the Mac built-in MCP server, Vault sync, unlimited Metrics and optional SFTP/port-forwarding multi-connection acceleration. Ordinary Workspace composition and SSH terminal uploads are free when their normal connection and destination gates pass. Tests and screenshot setups can create `.unrestrictedForTesting`; production must use RevenueCat status. On Mac `.mcpServer` gates the built-in server; mobile uses `.remoteMCP` for remote connections. The enumeration alone is not a platform availability promise.

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
    UI->>Gate: purchase or restore started
    UI->>RC: SDK purchase or restore
    RC-->>Gate: CustomerInfo update
    UI->>Gate: operation completed
    Gate->>RC: refresh current status
    Gate-->>Native: updated account variant
```

Purchase and restore callbacks refresh the controller's entitlement status while the native sheet can remain open on the account variant.

Both wrappers refuse purchase initiation if access already exists, mark operations processing on purchase/restore start and clear processing on completion, cancellation or failure. Completion refreshes entitlement without closing the sheet: the first RevenueCat dismissal request after purchase is suppressed so the account variant remains visible; the close button or subsequent dismissal can close it. Disappearance clears the processing flag. Mac chooses one owner window for the sheet; iOS presents it from `MobileRootView`. Confirm purchase/restore failures and recovery in real UI rather than assuming controller unit tests exercise SDK purchases.

## Release validation

1. Reconcile product IDs, types, group, Family Sharing, introductory eligibility and grace settings in App Store Connect **and** entitlement-to-product mapping, offering/paywall rules and localized disclosure in RevenueCat. Test new versus used-offer accounts, trial-to-paid renewal, cancellation through expiry, billing retry with and without grace, refunds, Family Sharing and lifetime restoration across Mac, iPhone and iPad. Record Sandbox results separately from the fixture and production configuration review.
2. Run the default shared/macOS tests as described in [Build, validation, localization and dependency release operations](build-test-and-release.md). `FrameworkTests/RevenueCatCommerceTests.swift` tests key validation, configured-entitlement resolution, expiration/grace/refund/verification, completion, stream updates, refresh races and failure recovery using decoded CustomerInfo and fake services. `FrameworkTests/ProPaywallStateTests.swift` tests dashboard variable mapping; `TFMTests/ProAccessTests.swift` tests gate semantics. There is no current `ProOfferPresentationTests`, `ProPaywallPresentationTests`, `TFMTests/ProPaywallRenderingTests` or `TFITests/ProPaywallRenderingTests` to validate remote paywall rendering. Check both native remote paywalls visually with live Sandbox metadata and dynamic type; unit and fixture tests do not cover a real SDK purchase, restore or the dashboard layout.
3. Check the final localized **storefront imagery** separately from the paywall. `Marketing/AppStore/en`, `Marketing/AppStore/zh-hans` and `Marketing/AppStore/zh-hant` contain Mac, iPhone 6.5-inch and iPad 13-inch sets of six JPG boards; review language, dimensions, platform promises and offer claims against current storefront terms before upload. These are final boards, distinct from the capture/device-frame inputs for the website. See [Marketing assets and app icons](marketing-assets-and-app-icons.md) for the production workflow.
4. Keep evidence separate: the StoreKit fixture verifies catalog *shape*; resolver tests verify local policy; signed-build checks verify credentials/capabilities; Sandbox and dashboard checks verify actual product delivery, eligibility, purchase, restore, legal copy, accessibility and Family Sharing. Coordinate changed app strings, website claims and imagery with remote paywall copy without silently changing product IDs or entitlement mapping.
