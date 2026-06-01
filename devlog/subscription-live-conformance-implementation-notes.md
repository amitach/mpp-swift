# Subscription live cross-SDK conformance (A2) - implementation notes

## Goal
Close the loop on the on-chain subscription vertical: have the **mppx reference client**
activate a subscription against **our** Swift server over a real socket, and have our
`TempoSubscriptionRenewer` settle period 0 **on-chain on live Moderato** (charge-on-activate).
A PASS proves the mppx client's signed `TempoKeyAuthorization` is accepted by our verifier AND
that our renewer's `transferWithMemo` mines successfully.

The offline reverse-conformance (activation only, no settlement) already passed (A1, #98); A2
adds the live settlement.

## The blocker: `SpendingLimitExceeded`
The first live charge reverted with `SpendingLimitExceeded` even though the payer was funded and
the transfer (1000) was well under the per-period limit.

Diagnosed by reading the on-chain `AccessKeySpend` events for the reverted tx: there were **two**
spends against the access key's per-period limit, not one:
1. ~120000 token-units for the gas of provisioning the access key (~4M gas), and
2. 1000 for the `transferWithMemo`.

So gas is metered against the **same** access-key spending limit as the transfer. Both SDKs set
`limit = request.amount` on activation, so `gas + transfer` blows the limit on the provisioning
charge. It was not a decimals bug and not specific to the fee token (reproduced with `feeToken:
nil`); the limit sweep confirmed it (limit must exceed `gas + amount`, not just `amount`).

## The fix: fee-payer (gas sponsor) - the peer's way
mppx's `submitSubscriptionPayment` sponsors gas with a fee payer so the access key's limit only
has to cover the transfer. Ported the same:

- **FFI** (`rust/tempo-tx-ffi`): `build_signed_tx` / `build_subscription_charge_tx` and the UniFFI
  `build_subscription_charge_transaction` gained an optional `fee_payer_private_key`. When set, the
  tx carries `fee_payer_signature = Some(FEE_PAYER_SIGNATURE_MARKER)` and is signed a second time
  over `tx.fee_payer_signature_hash(sender)` with the sponsor key; that account pays gas. The
  sponsor key is zeroized after use like the access key. Golden test + `cargo test` (11/11),
  fmt+clippy clean. Released as **`tempo-tx-ffi-v0.0.5`** (the FFI signature changed, so a new
  binary + `tempoFFIReleaseURL`/`Checksum` bump are mandatory).
- **Swift seam**: `TempoSubscriptionChargeParameters.feePayerPrivateKey` (optional, defaults nil so
  the proof/offline paths are unchanged); `FFISubscriptionChargeTxBuilder` passes it through;
  `TempoSubscriptionRenewer` gained an optional `feePayer: (@Sendable () async -> Data?)?` provider
  (a server-wide gas sponsor, not per-subscription). Default nil = payer pays its own gas.
- **Conformance**: the live route reads `CONFORMANCE_FEE_PAYER_KEY`; `run-subscription-live.sh`
  funds that sponsor address via the faucet (native gas) before boot, alongside the client payer.

## Verification
- Live FFI-path diagnostic (temporary, since deleted): at `limit == charge == 1000`, the
  unsponsored charge reverts `SpendingLimitExceeded`, the sponsored charge settles. Proves the fix
  end-to-end at the FFI layer before wiring the Swift seam.
- Full live e2e `Scripts/conformance/run-subscription-live.sh`: **PASSED** - mppx client activates,
  our renewer settles period 0 on-chain (e.g. ref `0x9f03...`), server logs
  `CHARGED (subscription-live) renewed(period: 0, ...)`.
- Hermetic suite gate-on: 674 tests pass. swiftformat --lint + swiftlint --strict clean; no em
  dashes. Gate-off (proof-only) build is green only **after** the v0.0.5 release is pointed at
  (the checked-in UniFFI binding calls the new signature).

## Decisions / deviations
- **Fee payer is a server-wide sponsor**, modelled as an injected key provider on the renewer
  (mirrors the `submit`/`nonceProvider` closure seams), not a per-subscription field. Keeping it
  optional means the proof, offline-subscription, and direct-wallet paths are untouched.
- **`feeToken: nil`** (gas in native) on the conformance route; the sponsor holds faucet native
  gas. The limit still only needs to cover the transfer because the sponsor pays gas, not the
  access key.
- **`gasLimit: 6_000_000`** on the live route: provisioning (key authorization → AccountKeychain)
  is ~4M gas; later charges are far cheaper but the cap is harmless.
- **File split**: the live (network-settling) routes moved from `ConformanceServer.swift` to
  `LiveConformanceRoutes.swift` (the FFI-gated session + subscription-live middleware), keeping
  each file under the length limit. `chainId`/`secret`/`log`/`subscriptionRecipientHex` became
  internal so the split file can share them. No behaviour change.

## Review hardening (Devin, PR #99)

- **Fee-payer key zeroization (real bug, fixed).** The first cut zeroized the sponsor key only on
  the happy path inside `build_signed_tx`, and not at all in `build_subscription_charge_tx` (where
  `[u8; 32]` is `Copy`, so the caller frame keeps a copy) nor in the UniFFI export (which
  dereferenced out of the `Zeroizing` wrapper into a bare array). Fixed all three: `build_signed_tx`
  now parses + wipes both keys *before* any fallible `?`, so no early return leaks; the caller wipes
  its `Copy`; the export keeps the sponsor key in `Zeroizing` and hands down only a `Copy`. The
  sponsor key is *borrowed* (via `as_ref`), not `take()`-moved: moving a `Copy` `[u8; 32]` out of
  the `Option` would leave the original payload bytes un-wiped (`None` rewrites only the
  discriminant), so it stays `Some` and the in-place `zeroize()` overwrites the real bytes (a
  second-round review catch). The golden tests confirm the signed bytes are unchanged (only
  zeroization moved). Requires another FFI release (binary behaviour changed, signature did not).
- **Live-subscription route now opt-in** (was always returning non-nil). It guards on
  `CONFORMANCE_FEE_PAYER_KEY` (which it requires to succeed anyway), matching how
  `makeSessionMiddleware` gates on `CONFORMANCE_OPERATOR_KEY`. A proof-only run no longer touches
  the RPC at startup, and the `Optional` return is meaningful.
- Other Devin notes were informational and intended: fee-payer is wired only for subscriptions (the
  only access-key/spending-limit path: see the table in the PR), gas price is read once at startup
  (fine for a dev harness), and the `private`->`internal` relaxation is the deliberate file split.

## Out of scope
- Per-subscription sponsors / sponsor rotation: the renewer takes a single provider; a production
  caller can return different keys, but the conformance uses one.
- A production renewal scheduler: `ActivateThenChargeVerifier` charges period 0 at activation,
  standing in for a scheduler. The engine's exactly-once claim/commit is what a scheduler reuses.
