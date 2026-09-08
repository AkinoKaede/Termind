# App Store commerce configuration

Termind Pro is a permanent, non-consumable purchase. The trial is a separate free,
non-consumable product. Neither product is a subscription, and the trial cannot
charge or renew automatically.

## Products

| Field | Permanent Pro | Free trial |
| --- | --- | --- |
| Product ID | `com.akinokaede.termind.pro` | `com.akinokaede.termind.pro.trial` |
| Type | Non-Consumable | Non-Consumable |
| Reference name | Termind Pro Lifetime | Termind Pro 14-Day Trial |
| Price | Keep the existing regional prices | Free / Price Tier 0 in every offered region |
| Family Sharing | Keep enabled | Disabled |
| English display name | Termind Pro | 14-day Trial |
| Simplified Chinese display name | Termind Pro | 14天试用 |

Trial descriptions:

- English: `Try all Pro features free for 14 days.`
- Simplified Chinese: `免费试用Termind Pro全部功能14天，到期不会自动扣费。`

In App Store Connect, create the trial under Termind's In-App Purchases, using the
exact ID above. Add both localizations, configure free pricing and availability,
and supply a review screenshot showing the trial button, duration, restricted Pro
features, permanent unlock price, and no automatic charge. Keep Family Sharing off
for the trial. Submit the new IAP with the app version that supports it, following
App Store Connect's submission requirements for the app's current IAP status.

`StoreKit/Termind.storekit` is only local test configuration. Editing it does not
create or change an App Store Connect product. Do not release the feature until the
online trial product is configured and available for the intended app release.

## Suggested App Review notes

Termind offers a 14-day trial through the free non-consumable in-app purchase
`com.akinokaede.termind.pro.trial` (14-day Trial), consistent with App Review
Guideline 3.1.1. The paywall displays the duration, the Pro features that require
purchase after expiration, and the localized permanent unlock price before the
trial can be claimed. The trial does not create a subscription and never charges
automatically. Access expires 1,209,600 seconds after the verified original purchase
date. Restoring the trial does not restart it. Termind Pro remains a separate
permanent non-consumable purchase with Family Sharing.

For expiration UI review, tap the Termind Pro heading seven times, open App Review
Demo, enter `TERMIND-REVIEW-2026`, and select Show Expired Trial. Exit Demo Mode to
return to real StoreKit access. This control only denies access; it never grants a
purchase or a trial. A verified permanent purchase overrides the demo.

## Local and Sandbox verification

The normal shared Termind scheme continues to use real StoreKit. For manual local
simulation, explicitly select `StoreKit/Termind.storekit` in the scheme's Run
options and remove the selection when finished. The automated `StoreKitTrialTests`
use `SKTestSession` with this file directly, disable purchase dialogs, and clear
only local simulated transactions between tests. On the current macOS hosted test runner,
approved transactions can appear in history without a pushed update; the regression invokes the
production update handler with that actual verified result. Verify real push delivery in Sandbox.

After the App Store Connect product is ready, verify with a Sandbox tester:

1. Open the paywall in English and Simplified Chinese. Confirm 14 days, Pro feature
   restrictions, localized permanent price, and no automatic charges.
2. Claim the free trial. Confirm the system sheet says free and the app shows an
   expiration 14 days after the original transaction. Cancel a separate attempt
   using a fresh tester and confirm no access is granted.
3. Restart and restore with the same tester. Confirm the expiration is unchanged.
   On another Mac, use the same App Store account; iCloud sign-in is not required
   to determine trial eligibility.
4. Exercise pending approval, failed product loading, purchase failure, and
   restore failure. Existing verified access must remain usable during metadata
   or purchase failures. Resolve pending approval and confirm the transaction
   listener updates access.
5. Buy permanent Pro during the trial and restore it. Confirm permanent access
   takes precedence and Pro Family Sharing remains supported.
6. Use automated local date-boundary tests for day 7, immediately before day 14,
   and the exact expiration instant. The App Review demo checks expired UI only;
   it is not a substitute for these entitlement tests.
7. Verify revoked trial history remains claimed and does not create a fresh trial.
   A price other than zero, a wrong product type, missing Pro pricing, or trial
   Family Sharing being enabled must prevent trial purchase.

## Eligibility and compatibility

Previous local seven-day trial records are ignored. Users who have not bought Pro
can claim the new 14-day IAP even if their old trial ended. No legacy records are
migrated or deleted. Vault CloudKit sync and user credential Keychain storage are
unrelated and remain unchanged.

StoreKit is the source of purchase eligibility and the original start date.
A local UserDefaults watermark keyed by the original transaction ID only prevents
ordinary backwards-clock changes from reactivating an observed expired trial. It
cannot grant access. It is not tamper-proof and does not identify a person or stop
someone using another App Store account. No licensing server or device fingerprint
is introduced.

References: [App Review Guideline 3.1.1](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase),
[originalPurchaseDate](https://developer.apple.com/documentation/storekit/transaction/originalpurchasedate),
[currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements),
[transaction history](https://developer.apple.com/documentation/storekit/transaction/all).
