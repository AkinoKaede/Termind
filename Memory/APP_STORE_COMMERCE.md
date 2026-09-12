# App Store commerce configuration

Termind Pro and its trial are separate non-consumables. The trial is free, lasts
14 days, never renews or charges, and does not support Family Sharing.

## Products

| Field | Permanent Pro | Free trial |
| --- | --- | --- |
| Product ID | `com.akinokaede.termind.pro` | `com.akinokaede.termind.pro.trial` |
| Reference name | Termind Pro Lifetime | Termind Pro 14-Day Trial |
| Price | Existing regional prices | Free / Tier 0 in every offered region |
| Family Sharing | Enabled | Disabled |
| English name | Termind Pro | 14-day Trial |
| Simplified Chinese name | Termind Pro | 14天试用 |

Trial descriptions:

- English: `Try all Pro features free for 14 days.`
- Chinese: `免费试用Termind Pro全部功能14天，到期不会自动扣费。`

Create the trial in App Store Connect with the exact ID, localizations, free
pricing, availability, and a review screenshot showing the button, duration,
gated features, permanent price, and no automatic charge. Submit it with the
supporting app version and keep Family Sharing off. `StoreKit/Termind.storekit`
is local test data only; it cannot create or modify the online product.

## App Review note

The free non-consumable trial follows Guideline 3.1.1. Access expires 1,209,600
seconds after the verified `originalPurchaseDate`; restore never restarts it.
Permanent Pro is a separate lifetime non-consumable and takes precedence.

To demonstrate expiration, tap the Termind Pro heading seven times, open App
Review Demo, enter `TERMIND-REVIEW-2026`, and choose Show Expired Trial. Demo
mode can only deny access; exit it to return to real StoreKit state.

## Release verification

Automated `StoreKitTrialTests` use `SKTestSession` and the local configuration.
The shared scheme normally uses real StoreKit. A hosted test may place an approved
transaction in history without delivering an update, so real listener delivery
must still be checked in Sandbox.

With Sandbox testers, verify:

1. English/Chinese paywalls show 14 days, gated features, localized permanent
   price, and no charge or renewal.
2. Claim, cancellation, restart, restore, and same-account cross-device behavior;
   expiration must stay anchored to the original transaction.
3. Pending approval, metadata failure, purchase failure, restore failure, and
   transaction-listener recovery without removing already verified access.
4. Permanent purchase during trial and restore; it must win and keep Family Sharing.
5. Day 7, just before day 14, and exact-expiration boundaries in automated tests.
6. Revoked trial history remains claimed. Nonzero price, wrong type, missing Pro
   price, or trial Family Sharing must block purchase.

StoreKit history is the sole eligibility/start-date source. Previous local
seven-day trials are ignored and not migrated, so users without Pro may claim the
new IAP. A UserDefaults high-water mark keyed by original transaction only guards
ordinary clock rollback; it cannot grant access or prevent account changes. There
is no licensing server or device fingerprint, and Vault/Keychain sync is unrelated.

References: [Guideline 3.1.1](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase),
[`originalPurchaseDate`](https://developer.apple.com/documentation/storekit/transaction/originalpurchasedate),
[`currentEntitlements`](https://developer.apple.com/documentation/storekit/transaction/currententitlements),
and [transaction history](https://developer.apple.com/documentation/storekit/transaction/all).
