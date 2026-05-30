# PR-G: TempoChannelSession (the client channel-session actor)

Generalizes the proven on-chain primitives (open/voucher/close, PR-F) into a reusable,
stateful, concurrency-safe API a self-managing wallet calls: open a channel, accumulate
vouchers, top up, close. This is the **direct on-chain** client mode; the 402-server
payment integration (emitting the payloads a server relays/settles) is PR-H, built on this.

## Why an actor + an in-flight guard (axiom-concurrency consulted; Devin 🔴 corrected)
The session holds mutable channel state across async ops. An `actor` is the right primitive
(non-UI subsystem, independent mutable state) and makes synchronous state access race-free.

**Reentrancy guard (Devin 🔴 on the first cut):** the actor ALONE does not serialize end to
end. Reentrancy means another method runs at an `await`, so two concurrent
`open`/`topUp`/`close` would interleave at the broadcast `await` and both read the same
nonce, colliding (my first version wrongly claimed the actor gave nonce sequencing for
free). Fix: an explicit `inFlight` guard, set/checked synchronously (atomic on the actor),
rejecting a concurrent op with `operationInProgress`. A deterministic unit test
(`reentrancyGuard`, a gated stub that parks op1 mid-flight) proves the rejection.

**Course-correction: adopt mppx's `eth_sendRawTransactionSync` (user steer "learn from mppx").**
My first cuts broadcast with `eth_sendRawTransaction` + a client-side receipt POLL LOOP, then
spent two Devin rounds patching the failure paths of that loop (a `poisoned` flag on receipt
timeout, recording state before a read-back, etc.). Reading mppx's `Chain.ts` showed it does
none of that: it uses **`eth_sendRawTransactionSync`** - Tempo's submit-and-wait RPC that
blocks server-side and returns the receipt in one round trip - and just checks
`receipt.status`. Verified Moderato supports it (a malformed tx gets `-32602 decode failed`,
not method-not-found). Switching to it **structurally removes** the poll loop, the receipt
timeout, AND the whole poison/refresh apparatus those rounds added: there is no client-side
timeout to be ambiguous about, and the per-op pending-nonce re-read means even a transport
hiccup can't cause a nonce collision on the next op. Also tracks deposit/cumulative LOCALLY
from the confirmed amounts (open = the arg, topUp = arithmetic), like mppx - no per-op chain
read-back, so the read-back failure mode disappears too. Result is simpler, faster (live e2e
3.1s vs ~4.5s, no poll), and correct by construction rather than by patching. Lesson saved in
memory ([[feedback_actor_reentrancy_not_serialization]]).

`channelID` is a `nonisolated let` (Sendable, immutable) so it reads without `await`.

## API
- `init(privateKey:escrow:token:payee:salt:fee:chainID:rpc:)` - derives the sender (= payer
  = authorizedSigner), computes the deterministic channelID (`Channel.id`), and builds the
  `FFITempoTxBuilder` internally (one key in).
- `open(deposit:) async -> ChannelSessionState` - build + sync-broadcast open; on confirm,
  record opened + the deposit (from the arg).
- `topUp(additionalDeposit:) async -> State` - build + sync-broadcast; add to the deposit.
- `voucher(cumulativeAmount:) -> SignedVoucher` - sign off-chain; enforces strictly
  increasing + within-deposit; records as the latest.
- `close() async -> State` - build + sync-broadcast close with the latest voucher (or a
  0-voucher); on confirm, finalized.
- `state()` snapshot; typed `TempoChannelSessionError`.

`broadcast` = `eth_sendRawTransactionSync` + a `succeeded` check (revert -> recoverable
`transactionReverted`, the nonce is consumed and the next op reads it fresh).

Scope note: this is the single-account self-managing path (payer = authorizedSigner). A
separate-access-key variant (root funds, access key signs vouchers) is a later extension.

## Tests
- **Hermetic unit tests** (`TempoChannelSessionTests`, a method-aware stub `EVMRPC` that
  answers the nonce read + `eth_sendRawTransactionSync` with a success/reverted receipt, no
  network): open tracks the deposit; topUp adds; vouchers strictly increase + stay within
  the deposit; pre-open ops rejected (`notOpen`); double-open rejected; close finalizes then
  rejects further ops; a reverted broadcast surfaces as `transactionReverted` (no poison);
  the reentrancy guard; invalid key at init.
- **Live** (`ModeratoE2ETests.sessionLifecycle`, gated): the actor drives a real
  open(1000) -> voucher(300) -> topUp(+500 -> 1500) -> close(finalized) on Moderato.

## Verified
16 gated FFI tests (incl. 9 session unit tests) + both live tests pass; default suite 450
green; swiftformat / swiftlint --strict / em-dash clean.

## Next (PR-H)
402-server channel payments: wire the session into MPPClient's PaymentMethodClient so a
client auto-pays a server over a channel, emitting the open/topUp/voucher/close payloads the
server's SessionMethod consumes; cross-SDK conformance against mppx's server.
