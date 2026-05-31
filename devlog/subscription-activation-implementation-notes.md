# Subscription activation wiring: implementation notes

> Deferred follow-up #2 from the subscription rail (PRs #84-#90): persist a *verified*
> subscription into the `SubscriptionStore` so the `SubscriptionEngine` can renew it.
> Follow-up #1 (a concrete on-chain `SubscriptionRenewer`) is a separate FFI vertical
> and is NOT in this change.

## The gap

`TempoSubscriptionVerifier.verify()` proves the signed `TempoKeyAuthorization` and mints a
`Receipt`, but nothing turns that into a `SubscriptionRecord`. So the store/engine never learn
the subscription exists, and `renew()` has nothing to charge. This change adds the seam that
takes a verified activation and persists it via the existing rail-agnostic
`SubscriptionEngine.activate(_:now:)`.

## Design (reuse the existing primitive, no parallel path)

1. **Expose the verification result.** Refactor `TempoSubscriptionVerifier`: extract the body of
   `verify()` into `verified(_:now:) -> Verified` (a new `Verified` value carrying `request`,
   `payer`, `serializedAuthorization`, `chainID`). `verify()` now delegates to it and maps to the
   same `Receipt`: identical behavior and error order, just the data is now reusable.
2. **Tempo glue → record.** `Verified.subscriptionRecord(subscriptionID:lookupKey:billingAnchor:
   lastChargedPeriod:)` assembles a `SubscriptionRecord` from the verified terms.
3. **Convenience.** `SubscriptionEngine.activate(_ verified:subscriptionID:lookupKey:billingAnchor:
   lastChargedPeriod:now:)` builds the record and calls the canonical `activate(_:now:)` (which
   already handles supersession). The core engine stays rail-agnostic; the Tempo-specific
   construction lives in the glue file.

## Decisions the spec did not pin

- **`lookupKey` + `subscriptionID` are caller inputs.** They are application identity (which
  customer / plan) and are not in the credential, so the SDK cannot invent them. The verified
  economic terms, payer, chain, and signed authorization all come from the credential.
- **`billingAnchor` is the activation instant** (caller passes `now`); period 0 is
  `[anchor, anchor + period)`.
- **`lastChargedPeriod` defaults to `nil` (period 0 owed).** The peer's conformance harness sets
  `lastChargedPeriod: 0` because *its* `activate` hook doubles as the operator's period-0
  settlement (returns a tx reference). Our verifier does NOT settle on-chain (that is the deferred
  renewer), so claiming period 0 is charged would be false. Default `nil` = "active, nothing charged
  yet; the renewal engine charges period 0 onward." An operator that settles at activation passes
  `0` explicitly. The record shape is internal server state, not conformance-gated, so this is safe.

## Not in scope (noted, not silently dropped)

- Wiring activation into the dev `MPPConformanceServer` `/subscription` route: its middleware
  `event` callback is synchronous and the store update is `async`, so a clean hook needs an async
  activation path through the middleware (a small separate follow-up). The seam + hermetic tests
  are the deliverable here (the same tests-as-caller pattern the channel `TempoChannelMethod`
  shipped with).
- The concrete on-chain renewer (follow-up #1).

## Verification
- `swift build`, `swift test` (full + new suite), `swiftformat --lint .` + `swiftlint --strict`.
- No em dashes; no `Co-Authored-By` trailer.
