# PR-H.2: cross-SDK channel-payment conformance - implementation notes

Live, bidirectional, full-lifecycle (open + voucher + close) cross-SDK conformance for the
Tempo payment-channel rail, on the Moderato testnet (faucet-funded). Running log of
decisions/deviations. Scope chosen by the user: BOTH directions + open/voucher/close.

## Defining constraint

Non-zero channel settlement is inherently on-chain: mppx's `tempo.session()` server REQUIRES
a signing account + RPC and relays/settles live (`broadcastOpenTransaction`, `settleOnChain`,
`closeOnChain`), and our client's open tx needs the FFI builder. So both directions are LIVE
Moderato tests, faucet-funded, double-gated (`MPP_TEMPO_FFI` + a conformance gate),
CI-optional. There is no hermetic relay/settle. This mirrors `ModeratoE2ETests` (PR-F).

## REUSE MAP (do NOT duplicate - user directive)

Everything below already exists and is reused as-is; PR-H.2 is mostly wiring.

- **Client (forward):** `TempoChannelMethod` (PR-H) + `FFITempoTxBuilder` as its `openBuilder`
  + a `depositPolicy`. Do NOT reimplement open/voucher; the method already does it.
- **Server (reverse):** `MPPTempoServer.SessionMethod` + `RPCChannelStateProvider`
  (relay/settle) + `FFITempoTxBuilder` as its `TempoCloseTxBuilder` + `ChannelStore`
  (`Sources/MPPTempoServer/ChannelStore.swift`). Do NOT reimplement settle.
- **Funding/RPC:** the faucet (`tempo_fundAddress`), `makeFee`, `makeBuilder`, `broadcast`,
  `waitForSuccess`, `fundFreshAccount`, `randomBytes`, `hashes` helpers currently PRIVATE in
  `Tests/MPPTempoFFITests/ModeratoE2ETests.swift`. EXTRACT to a shared
  `Tests/MPPTempoFFITests/ModeratoTestSupport.swift` (internal) and have BOTH `ModeratoE2ETests`
  and the new conformance test use the one copy. `EVMRPC` (request escape hatch,
  sendRawTransactionSync, transactionCount, gasPrice, transactionReceipt) reused as-is.
- **Reverse HTTP server:** EXTEND `Sources/MPPConformanceServer/ConformanceServer.swift` with a
  `/session` route + session middleware; do NOT add a new server. Reuse its POSIX listener,
  `MPPServerMiddleware`, `ChallengeSigner`/`ChallengeMinter`/`PaymentVerifier` wiring pattern.
- **Forward Swift test:** new `ConformanceSessionTests` mirrors `ConformanceProofTests`
  (env-URL-gated) but also requires `MPP_TEMPO_FFI`; lives in `MPPTempoFFITests` (needs the
  builder). Reuse the URL-parse + `PaymentClient` + `URLSessionTransport` pattern.
- **Harness scripts:** add session variants reusing `run.sh`/`run-reverse.sh` structure
  (npm ci --ignore-scripts, boot + wait-for-listening + parse port, gated swift test, trap
  cleanup). Reuse the pinned `Scripts/conformance/package.json` (mppx 0.6.28, viem) - no new
  deps. mppx side: `mppx/server` `tempo.session(...)` and `mppx/client` `tempo(...)` auto mode.
- **Constants:** `TempoChain.moderatoTestnet` (42431), escrow `0xe1c4...a336`, TIP-20
  `0x20c0...0000`, RPC `https://rpc.moderato.tempo.xyz` - all already in the codebase; reuse,
  do not re-encode in new places (pull from a single shared source if needed).

## Plan / phases

P0 - **Refactor (anti-duplication):** extract the Moderato funding/fee/builder/broadcast
   helpers to `ModeratoTestSupport.swift`; repoint `ModeratoE2ETests` to it (no behavior
   change; full suite still green under the e2e gate). This is the foundation that keeps the
   new test from copying funding logic.

P1 - **Forward (our client -> mppx session server):**
   - Node harness: a session server (extend `server.mjs` or `session-server.mjs`) using
     `tempo.session({ account: operator, escrowContract, currency, amount, suggestedDeposit,
     testnet:true })`; fund the operator via the faucet RPC at boot.
   - `run-session.sh`: npm ci, boot, fund, run the gated forward Swift test.
   - `ConformanceSessionTests` (forward): fund a client payer (faucet -> gas + TIP-20),
     build `TempoChannelMethod(openBuilder: FFITempoTxBuilder, depositPolicy:)`, pay the
     session 402: charge #1 opens (server relays on-chain), charge #2 vouchers, then close.

P2 - **Reverse (mppx client -> our session server):**
   - Extend `MPPConformanceServer` with a `/session` route: `SessionMethod` +
     `RPCChannelStateProvider(rpc, closeTxBuilder: FFITempoTxBuilder)` + funded operator.
     NOTE: this adds an FFI dependency to `MPPConformanceServer` - gate that target/route on
     `MPP_TEMPO_FFI` so the default proof-only server stays FFI-free.
   - `session-reverse-client.mjs`: mppx `tempo(...)` auto-mode client (funded) pays our
     `/session`: open + voucher + close.
   - `run-session-reverse.sh` mirrors `run-reverse.sh`.

P3 - **CI:** a new optional (non-required) live job mirroring `live-moderato`
   (`MPP_TEMPO_FFI=1` + the conformance gate), forward and reverse. Keep hermetic CI untouched.

P4 - **Docs:** extend `CONFORMANCE.md` "Not yet covered" -> the session flow is now covered;
   note it is live-gated.

## Open questions / risks (to resolve as we go)

- Operator funding in the Node harness: the faucet grants both 0x20c0 TIP-20s + native gas;
  the operator only needs gas to relay/settle. Confirm `tempo_fundAddress` from Node works the
  same as from Swift.
- mppx session server config: does `tempo.session` need `amount` per request set server-side,
  and how it advertises `suggestedDeposit` in the 402. Verify against `server/Session.ts`.
- Testnet flake: each direction does 3+ on-chain txs (open relay, settle, close). Reuse the
  60s receipt-poll budget; keep the gate optional/non-required.
- The reverse server's `RPCChannelStateProvider` needs a funded operator key in-process; pass
  it via env (never commit a key).

## Status

P0: TODO. (Branch: feat/ws10-402-conformance, off c52a34e.)
