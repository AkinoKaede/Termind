---
type: storefront-release-operations
title: Storefront Commerce Release Checks
description: Cross-platform checks for Termind Pro annual trials, lifetime purchases, localized paywalls, App Store metadata, and storefront imagery before release.
tags: [app-store, storekit, commerce, subscriptions, localization, release]
verified:
  - by: openwiki/0.5.2
    at: 2026-09-25T12:50:34.482Z
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-a8a9aade8fbc89d5829a491e
    resource: repo://Frameworks/Resources/Localizable.xcstrings
  - id: openwiki-source-b37c974aaea12bd08606d67d
    resource: repo://Frameworks/TermindDomain/Commerce/ProAccessTypes.swift
  - id: openwiki-source-3aa42bdd0f8eaf866f06599f
    resource: repo://Frameworks/TermindInfrastructure/Commerce/ProAccessController.swift
  - id: openwiki-source-a298d9034d557f1b420cb306
    resource: repo://Frameworks/TermindPresentation/ProOfferPresentation.swift
  - id: openwiki-source-ff6aeac237822b937eb60926
    resource: repo://Frameworks/TermindPresentation/ProPaywallContent.swift
  - id: openwiki-source-f9f51dced2f50e794fadc9ab
    resource: repo://Frameworks/TermindPresentation/ProPaywallPresentation.swift
  - id: openwiki-source-3b424584de88a1150af27f83
    resource: repo://FrameworkTests/ProOfferPresentationTests.swift
  - id: openwiki-source-925cc598397685e13fcf56c4
    resource: repo://FrameworkTests/ProPaywallPresentationTests.swift
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
  - id: openwiki-source-0ffab0ae6452f870ce4a0efe
    resource: repo://TFI/Features/Commerce/MobileProView.swift
  - id: openwiki-source-bc6023e93d60f0fac1bbea53
    resource: repo://TFITests/ProPaywallRenderingTests.swift
  - id: openwiki-source-766dc23f16ac26a41a5b5c22
    resource: repo://TFM/Features/Commerce/ProPaywallView.swift
  - id: openwiki-source-0da64bbb5811b467bbf89b7f
    resource: repo://TFMTests/ProAccessTests.swift
  - id: openwiki-source-0dd012e3740bcc348fc36ccb
    resource: repo://TFMTests/StoreKitTrialTests.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-25T12:50:34.482Z" }
---

# Storefront Commerce Release Checks

App Store Connect is the production authority for products, offers, localized metadata, Family Sharing, grace period, and review behavior. `StoreKit/Termind.storekit` is a **local development/test fixture**, not a storefront deployment. Keep the product IDs stable and test with the local configuration, Sandbox, and the review environment rather than granting demo or App Review entitlement overrides. Separate evidence for local behavior from evidence for the live storefront.

## Product and offer matrix

| Field | Annual | Lifetime |
| --- | --- | --- |
| Product ID | `com.akinokaede.termind.pro.annual` | `com.akinokaede.termind.pro` |
| Reference / English name | Termind Pro Annual | Termind Pro Lifetime |
| Local US fixture price and type | $3.99/year, auto-renewable | $9.99, non-consumable |
| Simplified Chinese name | Termind Pro 年度订阅 | Termind Pro 永久版 |
| Traditional Chinese name | Termind Pro 年度訂閱 | Termind Pro 永久版 |
| English description | Annual AI, MCP & iCloud sync access. | Lifetime AI, MCP & iCloud sync access. |
| Simplified Chinese description | 按年使用AI、MCP与iCloud同步功能。 | 永久使用AI、MCP与iCloud同步功能。 |
| Traditional Chinese description | 按年使用AI、MCP與iCloud同步功能。 | 永久使用AI、MCP與iCloud同步功能。 |

The fixture marks both products Family Shareable; annual is in the `Termind Pro` subscription group with a one-year renewal and **one two-week free introductory period**. Verify the actual offer and eligibility with a fresh Sandbox account: prior use of an introductory offer can make the badge disappear without changing the configured offer. Billing Grace Period is controlled in App Store Connect, not represented by this fixture: confirm the intended 16-day, paid-to-paid-only production policy and exercise the actual grace state before relying on it. Do not treat fixture prices as a universal storefront price.

## Shared paywall contract

`ProAccessController` loads both products, accepts only a family-shareable non-consumable lifetime product and a family-shareable yearly auto-renewable annual product, and reports StoreKit display prices, billing period, free-intro duration, and intro eligibility. `canStartTrial` requires the purchasable annual product, an eligible account, and an actual zero-price free-trial offer; annual remains purchasable without an offer. The Mac `ProPaywallView` and iPhone/iPad `MobileProView` feed these values and their controller status into the same `ProPaywallContent` through `ProPaywallPresentation`. Both reload products on presentation and select lifetime if annual metadata is unavailable but lifetime metadata exists. Mac supports the built-in MCP server in feature copy and opens the App Store subscriptions URL; mobile advertises remote MCP only and opens the system manage-subscriptions sheet.

```mermaid
flowchart TD
    Store["StoreKit products and verified transactions"] --> Controller["ProAccessController"]
    Controller --> Metadata["Price and trial metadata"]
    Controller --> Access["Entitlement status"]
    Metadata --> Mac["Mac paywall adapter"]
    Access --> Mac
    Metadata --> Mobile["Mobile paywall adapter"]
    Access --> Mobile
    Mac --> Shared["ProPaywallContent and ProOfferPresentation"]
    Mobile --> Shared
    Shared --> Actions["Purchase restore and reload"]
    Actions --> Controller
    Shared --> Manage["Platform subscription management"]
```

The diagram shows the release-facing boundary: platform adapters supply live commerce values and actions; shared presentation supplies the localized offer and status UI. Subscription management goes through the Mac URL or mobile system sheet rather than a controller purchase action.

`ProOfferPresentation` formats the annual trial badge and the selected-plan detail in the effective locale. StoreKit's `weekOfYear` introductory period is converted to days before formatting, so the local two-week offer displays its full **14 days**, not a guessed duration. Eligible annual offers use **Start Free Trial** and “free, then [StoreKit price] per [billing unit]. Auto-renews until canceled.” Ineligible/no-offer annual purchases use **Subscribe Annually** and the price/renewal disclosure without a free claim. Lifetime uses **Buy Lifetime Access** and “One payment. No subscription or automatic renewal.” Missing annual price or billing period suppresses the annual detail; missing trial duration suppresses its badge, not the eligibility-based button title. `Frameworks/Resources/Localizable.xcstrings` contains the Simplified and Traditional Chinese offer strings; inspect the native resolved text rather than deriving it from the StoreKit product description. Do not hard-code fixture prices or the two-week duration into UI or access rules.

The shared view presents access state and dates, plan cards, feature disclosure, restore, legal links, and recovery controls. Plan cards and purchase buttons are disabled when that plan is unavailable or a purchase is processing; a missing price offers **Reload App Store Prices**. Restore remains available even with existing access; manage subscription is offered only for an account-owned subscription, not Family Shared or lifetime access. Purchase actions stay visible for progress or errors but cannot initiate another purchase when access already exists. At accessibility text sizes, purchase controls move into the scroll content and plan cards stack vertically instead of relying on a cramped bottom inset. Verify the feature list and free/Pro boundary against [Commerce, Localization, and Product Surfaces](/openwiki/concepts/commerce-localization-and-product-surfaces.md): free Workspace composition is not a Pro benefit; paid gates include assistant, file upload, Metrics limits, remote MCP, Mac-only MCP server, and Vault iCloud sync.

## Entitlement and failure checks

- A verified, non-revoked lifetime entitlement wins over annual status. A verified annual introductory trial, active subscription, or grace period grants Pro; cancellation keeps access through verified expiry. Billing retry without grace, upgrade-away, revocation/refund, and unverified transactions must not unlock Pro. An expired transaction normally maps to `.expired`, but the post-expiry StoreKit `.subscribed` fallback needs the boundary check below. Retired standalone trials are not an access source.
- Entitlement refresh and product metadata fetch are independent: launch starts both, and catalog failure can clear available product prices and show recovery without erasing verified access. The controller observes `Transaction.updates`; a verified update refreshes access and is finished, while an unverified update reports failure. Purchase success also refreshes and finishes the verified transaction; a pending Ask to Buy request blocks repeat purchases of that plan until approval arrives through a verified update. Restore uses `AppStore.sync()` and reports no active purchase or verification failure rather than manufacturing access.
- **Recheck at the access deadline, not just on the next app launch.** Each applied Pro-granting subscription status with an `expiresAt` schedules a cancellable task to sleep until that date and call `refresh()`; applying another status cancels the previous timer, and controller teardown cancels it too. The timer does **not** itself revoke access: `refresh()` re-reads StoreKit's verified lifetime and latest annual transaction, expiration and subscription/renewal state. The subscription check grants an unexpired, non-upgraded trial or subscription, grants grace only with a verified future grace-period end, and denies billing retry, expired and revoked states. **Check the boundary in Sandbox on an already-open app:** the post-expiry `StoreKit` `.subscribed` branch currently returns `.subscribed` even after the transaction's expiration date has passed, and there is no focused `StoreKitTrialTests` clock/expiration-timer test. Do not treat the timer or the existing trial-purchase test as proof that Pro drops precisely at expiration; verify expiry, renewal and grace transitions with actual StoreKit state and add a regression test before depending on that invariant.
- Product validation prevents a misconfigured annual period or non-family-shareable product from appearing purchasable. Recheck actual StoreKit and App Store Connect configuration when a plan unexpectedly vanishes instead of adding a UI fallback price. A local test-only unrestricted status is not a production entitlement override.

## Localized storefront and release gate

1. Reconcile the product matrix, trial, Family Sharing, and intended grace settings in **App Store Connect** for English, Simplified Chinese, and Traditional Chinese; compare the actual Sandbox display prices and subscription group, not only `StoreKit/Termind.storekit`. Verify new-account trial eligibility and used-offer ineligibility; trial-to-paid renewal, cancellation-through-expiry **while the app remains open**, billing retry/grace, refund/revocation, restore, Ask to Buy, and lifetime precedence on Mac, iPhone, and iPad. Verify the same Apple account across devices and Family Sharing with a separate family account.
2. Inspect both native paywalls with live StoreKit metadata: annual and lifetime selection, 14-day fixture trial disclosure when eligible, renewal/no-renewal language, status/date, restore/manage links, localized legal/disclosure text, disabled/missing-product and retry states, and readable layouts at accessibility sizes. Run `FrameworkTests/ProOfferPresentationTests.swift` and `FrameworkTests/ProPaywallPresentationTests.swift` for localized weekly duration, eligibility, missing metadata, entitlement labels/dates, disabled purchase and recovery behavior. **There is no `TFMTests/ProPaywallRenderingTests.swift` in the current suite.** Check the Mac paywall visually in the app; do not cite a nonexistent Mac screenshot test as evidence. `TFITests/ProPaywallRenderingTests.swift` alone exercises shared content in a temporary UIKit key window with injected free and subscribed states, fixed sample prices, English, zh-Hans and zh-Hant, phone- and tablet-sized frames, and regular/accessibility dynamic type. It checks scroll width and records PNG attachments and temporary previews, but does **not** contact StoreKit, mount the full `MobileProView`, or establish live pricing or actual entitlement. Opt in to this serialized key-window suite with `TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1`, `-parallel-testing-enabled NO`, and `-only-testing:TFITests/ProPaywallRenderingTests` (or set `TERMIND_MOBILE_UI_TESTS=1` in Xcode's test environment). Offscreen layout and logic tests can run by default; key-window tests need their own opt-in. Separately authorize `TFMTests/StoreKitTrialTests.swift` with `TERMIND_STOREKIT_TESTS=1` and `-only-testing:TFMTests/StoreKitTrialTests`: its serialized `SKTestSession` uses the local configuration for trial purchase/restore, lifetime precedence, cancellation/metadata failure, pending approval, unverified transactions, missing intro offer, invalid annual catalog, and empty restore. It is **not** an offscreen render suite, does not test the scheduled entitlement-expiration refresh or post-expiry StoreKit status, and cannot verify production authorization or subscription/grace policy. See [Build, Validation, Localization, and Dependency Release Operations](/openwiki/operations/build-test-and-release.md) for the general test invocation playbook.
3. Confirm the final localized **storefront imagery**, separately from paywall screenshots: `Marketing/AppStore/en`, `Marketing/AppStore/zh-hans`, and `Marketing/AppStore/zh-hant` each have Mac, iPhone 6.5-inch, and iPad 13-inch sets of six JPG boards. Review language, device/platform sizing, readable native chrome, and offer/product messaging against the current storefront metadata before uploading to App Store Connect. These are final boards, not the capture or device-frame inputs used by the website. For the generation and review workflow see [Marketing Assets, Screenshot Production, Figma Exports, and App Icons](/openwiki/operations/marketing-assets-and-app-icons.md).
4. Record App Store Connect/Sandbox checks independently of local tests and artwork export checks. Local rendering and `SKTestSession` cannot establish production metadata, approval behavior, cross-device delivery, or Family Sharing. Coordinate any changes to marketing and free-Workspace copy without silently changing the product IDs, offer terms, group, or grace policy.
