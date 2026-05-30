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

## Decisions made during implementation

- **No-dup HTTP glue:** extracted `harness-http.mjs` (Node<->Fetch adapter + `serve()` +
  faucet `fundAddress`/`waitForReceipt`/`rpc`); refactored `server.mjs` (proof) to use it, so
  the session server reuses it rather than copying the glue. Confirmed `Scripts/conformance/`
  is THE harness folder (not a new one) and `Sources/MPPConformanceServer/` is the Swift server.
- **`testnet: true` is enough** for the mppx session server: `defaults.rpcUrl[42431]` = Moderato
  RPC, escrow `0xe1c4..a336`, currency pathUSD - no custom viem chain/client needed, just a
  faucet-funded operator `account`.
- **Forward close path:** mppx's server settles on a client `close` action (`handleClose`,
  operator account). Our `TempoChannelMethod` has no client close yet (FU-2), so the forward
  test builds the close credential by hand from the latest voucher (reusing `Voucher.sign` +
  `Credential`) and lets the mppx operator settle it on-chain; then asserts `finalized` via
  `TempoEscrow.readChannel`. No new client API, no premature FU-2.
- Captured the emitted credentials via `PaymentClient`'s `onEvent` sink to get the channel id +
  cumulative for the close (no need to expose method internals).

## Status

- **P0 DONE** (committed af58933): `ModeratoKit` shared helpers.
- **P1 DONE + LIVE-VERIFIED**: `harness-http.mjs`, `session-server.mjs`, `run-session.sh`,
  `ConformanceSessionTests` (forward: open -> voucher -> close against the mppx session server,
  asserts finalized on-chain). `run-session.sh` PASSED live on Moderato (4.5s): mppx relayed
  our open, accepted our voucher, and its operator settled our voucher (channel finalized).
  - **Bug the live test caught (the point of cross-SDK):** `suggestedDeposit` is a TOP-LEVEL
    request field (sibling of `amount`), not a `methodDetails` member - PR-H decoded it from
    `methodDetails` and the hermetic test fixture put it there too (self-consistent but wrong;
    the test-fidelity trap, [[feedback_test_double_fidelity]]). Fixed `TempoChargeRequest` to
    decode the top-level field and corrected the fixture; hermetic 21/21 still green, live now
    PASSES. Verified vs mppx `Methods.ts:76-79` (server emits top-level) + `client/Session.ts:128`
    (client reads top-level).
- P2 (reverse), P3 (CI), P4 (docs): TODO. (Branch: feat/ws10-402-conformance, off c52a34e.)
