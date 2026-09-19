# App Store commerce

App Store Connect owns production metadata; `StoreKit/Termind.storekit` is local test data only. No App Review/demo
entitlement override: use StoreKit configuration, Sandbox or Apple's review environment.

## Products

| Field | Annual | Lifetime |
| --- | --- | --- |
| Product ID | `com.akinokaede.termind.pro.annual` | `com.akinokaede.termind.pro` |
| Reference / English name | Termind Pro Annual | Termind Pro Lifetime |
| US price / type | $3.99/year, auto-renewable | $9.99, non-consumable |
| Simplified Chinese name | Termind Pro 年度订阅 | Termind Pro 永久版 |
| Traditional Chinese name | Termind Pro 年度訂閱 | Termind Pro 永久版 |
| English description | Annual AI, MCP & iCloud sync access. | Lifetime AI, MCP & iCloud sync access. |
| Simplified description | 按年使用AI、MCP与iCloud同步功能。 | 永久使用AI、MCP与iCloud同步功能。 |
| Traditional description | 按年使用AI、MCP與iCloud同步功能。 | 永久使用AI、MCP與iCloud同步功能。 |

Both enable Family Sharing. Annual belongs to one `Termind Pro` subscription group with an introductory free trial
(currently two weeks); app eligibility/duration/price/billing period come from StoreKit, never hard-coded. Billing
Grace Period: 16 days, paid-to-paid only; Sandbox-test before Production.

## Access rules

- Permanent wins. Verified subscribed/trial/grace grants Pro; cancellation retains it through verified expiration.
  Billing retry without grace, expiration, upgrade-away, refund or revocation denies access. Metadata failure never
  removes verified access. Refresh on activation and consume `Transaction.updates` (including Ask to Buy completion).
- Features use current entitlement immediately. Mac Workspace composition, broadcast, batch opening, multi-host
  snippets and local templates are free; template iCloud sync remains Pro. Retired standalone trials do not grant access.

## Release checklist

- Run `StoreKitTrialTests`/`SKTestSession`. Repository changes do not update App Store Connect: explicitly apply all
  three localized descriptions above, coordinate website/free-Workspace copy, retain product IDs/prices/offers.
- With a new Sandbox account verify localized annual/lifetime price, period, introductory eligibility/duration;
  purchase/trial/renewal/cancel/restore/expiration/retry/paid-to-paid grace/refund/revocation/Ask to Buy/updates.
- Verify same-account Mac/iPhone/iPad access and Family Sharing. Local tests alone do not prove production metadata.

References: [subscriptions](https://developer.apple.com/app-store/subscriptions/),
[intro eligibility](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/iseligibleforintrooffer),
[entitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements),
[transaction history](https://developer.apple.com/documentation/storekit/transaction/all).
