# PR-H: Tempo 402-server channel-payment CLIENT (`TempoChannelMethod`) — implementation notes

Running log of decisions, deviations, and what was / was not verified. Companion to the
plan (`~/.claude/plans/nested-crafting-map.md`).

## What this is

`TempoChannelMethod: PaymentMethodClient`, the client that pays a `tempo`/`session` 402
challenge: the first charge to a `(payee, token, escrow)` builds the signed `open` `0x76`
transaction + an initial voucher and emits the `open` payload the server relays; each
later charge to the same triple signs a cumulative voucher and emits the `voucher`
payload (off-chain). A faithful port of mppx 0.6.28 `client/{Charge,Session,ChannelOps}.ts`
(auto-charge / `autoManageCredential`), not a reinvention.

## Decisions the spec/port did not pin down

1. **Intent is `session`, not `charge`.** My own port-spec note said "non-zero
   tempo/charge", but the merged server `SessionMethod.supports` matches
   `method == tempo && intent == .session`. The client must mirror the server, so the
   method targets `tempo`/`.session`. (The `.session` intent already existed in
   `IntentName`.) This is the single most important correction; the old note was stale.

2. **Builder seam, method in un-gated `MPPTempo` (user-confirmed).** Rather than place the
   method in the FFI-gated `MPPTempoFFI` target, I mirrored the existing `TempoCloseTxBuilder`
   primitive: added a `TempoOpenTxBuilder` protocol in `MPPTempo`, moved the pure
   `TempoOpenParameters` value type down from `MPPTempoFFI` to `MPPTempo`, and had
   `FFITempoTxBuilder` declare conformance (no body change). The method depends only on the
   protocol + a `Secp256k1Signer`, so it stays in the default (Rust-free) graph and its tests
   run un-gated with a stub builder, exactly like `TempoProofMethod`. The FFI binary is pulled
   only when a caller injects `FFITempoTxBuilder`.

3. **Injected deposit policy (user-confirmed).** The constructor takes a
   `depositPolicy: (DepositContext) -> String?` (throws `noDeposit` on nil). I added an optional
   `methodDetails.suggestedDeposit` decode to `TempoChargeRequest` and surface it in
   `DepositContext`. This abstracts mppx's `deposit / maxDeposit / suggestedDeposit` precedence
   ladder: a caller can replicate it exactly (incl. `min(suggested, maxDeposit)`), but the SDK
   does not hardcode one policy. The deposit is never the charge amount.

4. **Concurrency: registry registers inside the open task.** The channel registry is an
   `actor` keyed by `(payee, token, escrow)`. The first-charge `open` is gated by a stored
   in-flight `Task`; the entry is registered and the slot cleared **inside that task's final,
   actor-isolated step** (`register`), before the task returns. This was the fix for a real
   bug found in testing (see below).

## Parity check vs mppx 0.6.28 (line by line, internal verification)

Compared against `npm pack mppx@0.6.28` `src/tempo/client/Session.ts` (`autoManageCredential`),
`ChannelOps.ts` (`createOpenPayload`/`createVoucherPayload`), `Charge.ts`.

- **Exact**: open-vs-voucher branching (`entry?.opened` → `cumulative += amount` → voucher;
  else open with `initialAmount = amount`); `channelKey(payee, currency, escrow)`; `salt =
  random(32)`; `computeId({payer, payee, token, salt, authorizedSigner, escrow, chainId})`;
  the `[approve(escrow, deposit), open(payee, token, deposit, salt, authorizedSigner)]` tx with
  `feeToken = currency`; initial voucher for `amount`; `did:pkh:eip155:{chainId}:{address}`
  source; `authorizedSigner` defaulting to the account address.
- **Fixed gap**: mppx's open payload carries `type: "transaction"` (`ChannelOps.ts:197`);
  my first cut omitted it. Added it (and a test). Our server ignores it (it switches on
  `action`), but it is part of the canonical open payload and matters for cross-SDK (PR-H.2).
  The voucher/close payloads carry no `type` (asserted by test).
- **Deliberate deviations (consistent with our SDK, noted not bugs)**:
  - chainId fallback uses `defaultChainId` (mainnet) where mppx uses `?? 0`. Matches our
    existing `TempoProofMethod` convention; chainId 0 would be an unsigned-able domain anyway.
  - The escrow must be named in the challenge (no configured-override / chain-default lookup).
    Our server requires `request.escrowContract` (throws `missingEscrow`), so the challenge
    always carries it.
  - `authorizedSigner` is always the payer (no separate access-key signer). Matches PR-G's
    `TempoChannelSession`; the access-key feature is an advanced mppx option, deferred.
  - Added a `cumulativeOverflow` guard (mppx uses unbounded JS BigInt; our amounts are the
    escrow's `uint128`, so overflow is a real fail-closed case).

## Bug found and fixed during testing (not by Devin)

The concurrent-open test (`concurrentOpensOnce`, 12 charges racing one new key) **hung**. Root
cause: my first registry design had the opener register the entry and clear the in-flight slot
only **after its own continuation resumed** from `await task.value`, while 11 awaiters
busy-looped (`continue`) re-checking state. Under the cooperative executor the awaiters'
continuations could be scheduled ahead of the opener's, starving it. Fix: move the registration
into the open task itself (`register`, actor-isolated, sets the entry then clears the slot), so
any awaiter sees a consistent state the instant its `await` returns — at most two loop
iterations, no busy-wait, no continuation-ordering race. (Process note: the apparent multi-minute
"hangs" while diagnosing were compounded by leftover poll-watcher shells contending on the
SwiftPM `.build` lock; cleaned up.)

## What was verified

- `swift build` (gate off) and `swift build` would also exercise the FFI conformance via the
  published-release binaryTarget (`MPPTempoFFI` compiles the `TempoOpenTxBuilder` conformance).
- `swift test --filter MPPTempoTests.TempoChannelMethod`: 17/17 green, incl. byte-real voucher
  signature verification (`Voucher.verify`), exact open/voucher payload shapes, the deposit
  policy + `suggestedDeposit`, amount/cumulative `uint128` edges, approval-deny (no signature),
  concurrent single-open, and end-to-end through `PaymentClient`.
- `swiftformat --lint .` clean; `swiftlint --strict` 0 violations; no em dashes.
- Full `swift test` suite: see PR / CI.

## Not done (deferred, by scope)

- `tryRecoverChannel` (read an existing on-chain channel to attach to it). mppx only does this
  when the challenge/context suggests a `channelId`; our server does not, and it would make the
  client RPC-dependent. Follow-up.
- Client-side `topUp` / `close` (mppx's auto-charge path opens + vouchers only; topUp/close are
  the direct-wallet `TempoChannelSession`'s job).
- Separate access-key `authorizedSigner`.
- **PR-H.2**: cross-SDK conformance against mppx's own server with a funded non-zero
  relay/settle harness (the current conformance harness is zero-amount only).
