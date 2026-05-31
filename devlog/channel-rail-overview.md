# Tempo payment-channel rail: overview (the whole arc)

Where the Tempo channel rail stands, and the per-PR devlogs that detail each slice. The rail
is feature-complete (proof + payment-channel session, client + server, on-chain) and
cross-SDK conformance-proven against the reference SDK in both directions, live on Moderato.

## The arc (all merged on `main`)

1. **On-chain FFI vertical** (the `0x76` transaction builder): `rust/tempo-tx-ffi` binds
   Tempo's `tempo-primitives@1.8.0` over UniFFI; open/topUp/close builders on macOS/iOS/Linux;
   released as the checksum-pinned `tempo-tx-ffi-v0.0.1` xcframework (external Apple install,
   no Rust toolchain); proven by a live Moderato write-path e2e. Broadcast primitive:
   `eth_sendRawTransactionSync` (submit-and-wait), never a client poll loop.
2. **Server side**: `SessionMethod` (open/topUp/voucher/close verify) + `RPCChannelStateProvider`
   (reads + relays signed txs + settles via the close seam) + `ChannelStore`.
3. **Direct-wallet lifecycle**: `TempoChannelSession` (PR-G) drives open/topUp/voucher/close
   on-chain for a wallet that holds its own key.
4. **402 channel-payment client** (PR-H, #73): `TempoChannelMethod` pays a `tempo`/`session`
   402, auto-opening a channel on the first charge and accumulating off-chain vouchers after,
   behind the `TempoOpenTxBuilder` seam (a faithful port of the reference client's auto-charge
   flow). Lives in un-gated `MPPTempo`; the FFI is pulled only when a caller injects the builder.
5. **Bidirectional cross-SDK conformance** (PR-H.2, #74), live on Moderato: our client settled
   by the reference session server, and the reference client settled by our server. The live
   runs caught two real bugs (the `suggestedDeposit` wire location, and the session replay
   policy below).
6. **Follow-ups** (FU-1..4 + PR-G test gaps, #75):
   - **FU-1** `tryRecoverChannel`: attach to a server-suggested on-chain channel (guarded:
     drawable + payer/payee/token/authorizedSigner must match) instead of opening fresh.
   - **FU-2** client-initiated `buildTopUp` / `buildClose` (`TempoTopUpTxBuilder` seam; close is
     builder-free and the server settles).
   - **FU-3** separate access-key `authorizedSigner` (the access key signs vouchers + is the
     channel signer; the wallet funds and is the `did:pkh` source).
   - **FU-4** session replay policy: `PaymentMethodServer.reusesChallenge` (default false) so the
     verifier does not consume a session's reused challenge (anti-replay is the channel-store
     monotonic cumulative). The real production hardening surfaced by the reverse conformance.

## How to use it

- **Pay a session 402 (client):** construct `TempoChannelMethod(signer:, openBuilder:,
  depositPolicy:, ...)` and register it with `PaymentClient`. Repeat charges to the same
  `(payee, token, escrow, chainId)` voucher against one channel. Manage with `buildTopUp` /
  `buildClose`. Inject a `channelReader` to recover an existing channel; a `voucherSigner` for a
  separate access key.
- **Serve a session 402 (server):** `SessionMethod(provider: RPCChannelStateProvider(rpc,
  closeTxBuilder:), store:, ...)` registered in a `PaymentVerifier`. Pair it with a replay store
  that respects `reusesChallenge` (the default verifier already skips consume for it).
- **Verify cross-SDK:** `Scripts/conformance/run-session.sh` (forward) and
  `run-session-reverse.sh` (reverse) drive it live on Moderato; both run in the non-required
  `rust-ffi` macOS CI job.

## Per-slice devlogs

- `pr-h-channel-payment-client-implementation-notes.md` (PR-H client)
- `pr-h2-conformance-implementation-notes.md` (PR-H.2 bidirectional conformance)
- `pr-h-followups.md` (FU-1..4 + PR-G gaps)

## Pending (not channel-blocking)

Subscription sub-layer (RLP key-auth + VoucherStore + SSE), Stripe rail, framework adapters,
CLI, MCP, proxy, WebSocket, discovery PR-2, and the CI-optimization chore.
