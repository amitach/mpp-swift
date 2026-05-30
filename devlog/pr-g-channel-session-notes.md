# PR-G: TempoChannelSession (the client channel-session actor)

Generalizes the proven on-chain primitives (open/voucher/close, PR-F) into a reusable,
stateful, concurrency-safe API a self-managing wallet calls: open a channel, accumulate
vouchers, top up, close. This is the **direct on-chain** client mode; the 402-server
payment integration (emitting the payloads a server relays/settles) is PR-H, built on this.

## Why an actor + an in-flight guard (axiom-concurrency consulted; Devin 🔴 corrected)
The session holds mutable channel state across async ops. An `actor` is the right primitive
(non-UI subsystem, independent mutable state) and makes synchronous state access race-free.

**Correction (Devin 🔴 on the first cut):** the actor ALONE does not serialize end to end.
Actor reentrancy means another method can run at an `await` suspension point, so two
concurrent `open`/`topUp`/`close` calls would interleave at the broadcast `await` and both
read the same nonce, colliding. So the nonce-sequencing guarantee is NOT free from the actor
(my first version wrongly claimed it was). The fix: an explicit in-flight guard - a `private
var inFlight` set/checked synchronously (no await between check and set, so it is atomic on
the actor) that rejects a concurrent lifecycle op with `operationInProgress`. Driven
sequentially (await one op before the next), the writes are then nonce-sequenced correctly.
A deterministic unit test (`reentrancyGuard`, a gated stub that parks op1 mid-flight) proves
the rejection. Also (Devin 🚩) `broadcast` now documents its three outcomes so a caller can
tell "not submitted" (retry-safe) from "submitted but unconfirmed" (do not blindly retry).

`channelID` is a `nonisolated let` (Sendable, immutable) so it reads without `await`.

## API
- `init(privateKey:escrow:token:payee:salt:fee:chainID:rpc:pollInterval:maxPollAttempts:)`
  - derives the sender (= payer = authorizedSigner), computes the deterministic channelID
    (`Channel.id`), and constructs the `FFITempoTxBuilder` internally (one key in).
- `open(deposit:) async -> ChannelSessionState` - build+broadcast open, read back deposit.
- `topUp(additionalDeposit:) async -> State` - build+broadcast topUp, re-read deposit.
- `voucher(cumulativeAmount:) -> SignedVoucher` - sign off-chain; enforces strictly
  increasing + within-deposit; records as the latest.
- `close() async -> State` - build+broadcast close with the latest voucher (or a 0-voucher),
  confirm `finalized`.
- `state()` snapshot; typed `TempoChannelSessionError`.

Scope note: this is the single-account self-managing path (payer = authorizedSigner). A
separate-access-key variant (root funds, access key signs vouchers) is a later extension.

## Tests
- **Hermetic unit tests** (`TempoChannelSessionTests`, a method-aware stub `EVMRPC`
  transport, no network): open tracks the deposit; vouchers must strictly increase and stay
  within the deposit; pre-open ops rejected (`notOpen`); double-open rejected; close
  finalizes then rejects further ops; invalid key rejected at init. (The stub answers
  nonce/send/receipt and ABI-encodes a configurable `getChannel`.)
- **Live** (`ModeratoE2ETests.sessionLifecycle`, gated): the actor drives a real
  open(1000) -> voucher(300) -> topUp(+500 -> 1500) -> close(finalized) on Moderato.

## Verified
13 gated FFI tests (incl. 6 session unit tests) + the live session test pass; default suite
447 green; swiftformat / swiftlint --strict / em-dash clean.

## Next (PR-H)
402-server channel payments: wire the session into MPPClient's PaymentMethodClient so a
client auto-pays a server over a channel, emitting the open/topUp/voucher/close payloads the
server's SessionMethod consumes; cross-SDK conformance against mppx's server.
