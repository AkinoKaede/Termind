# App Store commerce configuration

Termind Pro offers an annual auto-renewable subscription and a permanent
non-consumable. Both support Family Sharing. The annual subscription owns its
introductory free trial; StoreKit metadata and verified transactions are the sole
sources for eligibility, offer duration, price, billing period, and expiration.

## Products

| Field | Annual | Lifetime |
| --- | --- | --- |
| Product ID | `com.akinokaede.termind.pro.annual` | `com.akinokaede.termind.pro` |
| Reference name | Termind Pro Annual | Termind Pro Lifetime |
| US price | $3.99/year | $9.99 |
| Type | Auto-renewable, one year | Non-consumable |
| Family Sharing | Enabled | Enabled |
| English name | Termind Pro Annual | Termind Pro Lifetime |
| Simplified Chinese name | Termind Pro 年度订阅 | Termind Pro 永久版 |
| Traditional Chinese name | Termind Pro 年度訂閱 | Termind Pro 永久版 |

Annual descriptions:

- English: `Annual AI, MCP & iCloud sync access.`
- Simplified Chinese: `按年使用AI、MCP与iCloud同步功能。`
- Traditional Chinese: `按年使用AI、MCP與iCloud同步功能。`

Lifetime descriptions:

- English: `Lifetime AI, MCP & iCloud sync access.`
- Simplified Chinese: `永久使用AI、MCP与iCloud同步功能。`
- Traditional Chinese: `永久使用AI、MCP與iCloud同步功能。`

Configure the annual product in one `Termind Pro` subscription group. Its
introductory offer is free and currently lasts two weeks, but the app never
hard-codes that duration. Billing Grace Period is 16 days, applies only to
paid-to-paid renewals, and must be tested in Sandbox before enabling Production.

`StoreKit/Termind.storekit` is local test data only. App Store Connect remains the
source of production product metadata and cannot be changed by the repository.

There is no review-demo access override. App Review and release verification use
the StoreKit configuration, Sandbox accounts, or Apple's review environment.

## Entitlement rules

Permanent access wins over every subscription state. A verified annual transaction
grants Pro while subscribed, during its introductory trial, or during a verified
billing grace period. Cancellation keeps access through the verified expiration.
Billing retry without grace, expiration, upgrade-away, refund, or revocation denies
access. Pro features use the current entitlement immediately. Mac Workspace
composition, broadcast input, batch opening, multi-host snippets, and local templates
are free regardless of entitlement; template iCloud sync still requires Pro.

Product metadata failure never removes already verified access. macOS and mobile
refresh on foreground activation, and `Transaction.updates` handles purchases,
renewals, refunds, revocations, and Ask to Buy completion.

## Release verification

Automated `StoreKitTrialTests` use `SKTestSession` and the local configuration.
Coordinate the website copy with the app release that makes Workspace composition
free. Update both products' English, Simplified Chinese, and Traditional Chinese
descriptions in App Store Connect to the text above; repository changes do not update
production metadata. Keep product IDs, prices, and offer configuration unchanged.

Before submission, verify with a new Sandbox account:

1. The paywall obtains the localized annual/lifetime prices, annual billing period,
   introductory-offer eligibility, and offer duration from StoreKit.
2. Trial purchase, renewal, cancellation, restore, expiration, billing retry, paid-
   to-paid grace, refund, revocation, Ask to Buy, and transaction updates.
3. Same-account access across Mac, iPhone, and iPad, plus Family Sharing.

References: [subscriptions](https://developer.apple.com/app-store/subscriptions/),
[`isEligibleForIntroOffer`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/iseligibleforintrooffer),
[`currentEntitlements`](https://developer.apple.com/documentation/storekit/transaction/currententitlements),
and [transaction history](https://developer.apple.com/documentation/storekit/transaction/all).
