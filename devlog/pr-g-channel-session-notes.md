# PR-G: TempoChannelSession (the client channel-session actor)

Generalizes the proven on-chain primitives (open/voucher/close, PR-F) into a reusable,
stateful, concurrency-safe API a self-managing wallet calls: open a channel, accumulate
vouchers, top up, close. This is the **direct on-chain** client mode; the 402-server
payment integration (emitting the payloads a server relays/settles) is PR-H, built on this.

## Why an actor (axiom-concurrency consulted)
The session holds mutable channel state (deposit, cumulative amount, open/finalized) across
async operations. Per the Swift-concurrency discipline, an `actor` is the right primitive
for a non-UI subsystem with independent mutable state: it serializes every operation, so
(a) the state mutates race-free, and (b) the transactions are **nonce-sequenced** correctly
(each op waits for its receipt before the next returns, so a fresh account's open is nonce
0, the next write nonce 1, ...). This is exactly the nonce-sequencing concern the #68 Devin
note said belongs to "the client session layer" - here it is, enforced by actor isolation +
receipt-waiting, not by the stateless builder.

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
