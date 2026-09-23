---
type: storefront-release-operations
title: App Store Commerce Configuration and Release Verification
description: Product metadata, entitlement expectations, App Store Connect ownership, and Sandbox/cross-device checks for Termind Pro.
tags: [app-store, storekit, commerce, subscriptions, release]
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T10:08:51.776Z
sources:
  - id: openwiki-source-b37c974aaea12bd08606d67d
    resource: repo://Frameworks/TermindDomain/Commerce/ProAccessTypes.swift
  - id: openwiki-source-3aa42bdd0f8eaf866f06599f
    resource: repo://Frameworks/TermindInfrastructure/Commerce/ProAccessController.swift
  - id: openwiki-source-9fc915d39c61b81a60426eb3
    resource: repo://StoreKit/Termind.storekit
  - id: openwiki-source-0da64bbb5811b467bbf89b7f
    resource: repo://TFMTests/ProAccessTests.swift
  - id: openwiki-source-0dd012e3740bcc348fc36ccb
    resource: repo://TFMTests/StoreKitTrialTests.swift
generated: { by: "codex", at: "2026-09-22T01:13:21.371Z" }
---

# App Store Commerce Configuration and Release Verification

App Store Connect is the production authority for products, offers, localized metadata, Family Sharing, grace period, and review behavior. `StoreKit/Termind.storekit` is a local development and test fixture; editing it does not update the storefront. Do not add a demo or App Review entitlement override. Exercise purchases with the local configuration, Sandbox, or Apple's review environment.

## Product matrix

| Field | Annual | Lifetime |
| --- | --- | --- |
| Product ID | `com.akinokaede.termind.pro.annual` | `com.akinokaede.termind.pro` |
| Reference / English name | Termind Pro Annual | Termind Pro Lifetime |
| US price and type | $3.99/year, auto-renewable | $9.99, non-consumable |
| Simplified Chinese name | Termind Pro 年度订阅 | Termind Pro 永久版 |
| Traditional Chinese name | Termind Pro 年度訂閱 | Termind Pro 永久版 |
| English description | Annual AI, MCP & iCloud sync access. | Lifetime AI, MCP & iCloud sync access. |
| Simplified Chinese description | 按年使用AI、MCP与iCloud同步功能。 | 永久使用AI、MCP与iCloud同步功能。 |
| Traditional Chinese description | 按年使用AI、MCP與iCloud同步功能。 | 永久使用AI、MCP與iCloud同步功能。 |

Both products enable Family Sharing. The annual product belongs to one `Termind Pro` subscription group, bills yearly, and has a free introductory offer currently configured for two weeks. Production Billing Grace Period is an App Store Connect setting: retain the intended 16-day, paid-to-paid-only policy and verify it in Sandbox before relying on it. The app obtains price, billing period, introductory eligibility, duration, and subscription state from StoreKit; never hard-code storefront display values into access logic or UI.

## Entitlement expectations

- A verified, non-revoked lifetime purchase wins over annual state.
- A verified annual introductory trial, subscribed period, or grace period grants Pro. Cancellation retains access through the verified expiration date.
- Billing retry without grace, expiration, upgrade-away, refund, revocation, or failed verification does not grant access.
- Product metadata/catalog failure must not remove already verified access. The controller refreshes entitlements independently, observes `Transaction.updates`, and handles deferred Ask to Buy completion.
- Protected features consult the current entitlement immediately. Free access still includes Mac Workspace composition, broadcast, batch opening, multi-Host snippets, and local templates; template iCloud synchronization remains Pro.
- Retired standalone trials are not an access source.

Keep runtime access behavior in the shared commerce controller and domain types. The local StoreKit file may mirror production configuration for testing, but it is not permission to infer the production state.

## Release verification

1. Run `StoreKitTrialTests` and the relevant `SKTestSession`/Pro access suites. Verify purchase, introductory trial, renewal, cancellation, restore, expiration, billing retry, paid-to-paid grace, refund, revocation, Ask to Buy, deferred completion, and transaction updates.
2. With a new Sandbox account, verify the localized annual and lifetime product names, descriptions, prices, annual period, introductory eligibility/duration, and Family Sharing. Existing accounts may already have consumed introductory eligibility.
3. Verify the same Apple-account entitlement on Mac, iPhone, and iPad, then verify Family Sharing separately. Confirm lifetime precedence and cancellation-through-expiry behavior.
4. Apply all English, Simplified Chinese, and Traditional Chinese metadata changes in App Store Connect. Coordinate storefront text with website and free-Workspace messaging while preserving the product IDs, prices, subscription group, offer, and grace policy.
5. Inspect native paywalls and subscription-management flows using StoreKit-provided metadata. Verify that metadata/network failure is recoverable and does not downgrade a verified user.
6. Record App Store Connect/Sandbox evidence independently from the local test result. Local tests cannot prove production metadata, review-environment behavior, cross-device delivery, or Family Sharing.

See [Commerce, Localization, and Product Surfaces](/openwiki/concepts/commerce-localization-and-product-surfaces.md) for runtime gating and paywall ownership, [Marketing Assets, Screenshot Production, Figma Exports, and App Icons](/openwiki/operations/marketing-assets-and-app-icons.md) for product imagery, and [Build, Validation, Localization, and Dependency Release Operations](/openwiki/operations/build-test-and-release.md) for ordinary validation.
