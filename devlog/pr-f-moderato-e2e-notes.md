# PR-F: live Moderato on-chain write-path e2e

The authoritative proof the whole FFI vertical works on a real chain: build (via the Rust
FFI), sign, broadcast, and confirm a real `open` + `close` of a payment channel against the
live Moderato testnet. The byte-golden tests defer to this for on-chain correctness.

## Self-contained via the faucet (no secrets)
Moderato exposes a faucet: JSON-RPC **`tempo_fundAddress([address])`** returns funding tx
hashes and grants the address native gas + the TIP-20 tokens (verified live: funding a
throwaway address returned 4 tx hashes and credited both `0x20c0…0000` / `0x20c0…0001`).
So the e2e generates a fresh throwaway key, faucet-funds it, and runs the whole flow with
no pre-funded account or committed secret. Each run is independent (nonce starts at 0).
See memory `reference_moderato_faucet_e2e`. The faucet is testnet-only, so the test calls
it via EVMRPC's public `request(...)` escape hatch rather than adding it to the production
API surface.

## The flow (ModeratoE2ETests, gated by MPP_MODERATO_E2E + MPP_TEMPO_FFI)
fresh key → `tempo_fundAddress` → wait receipts → build open (FFI 2-call approve+open) →
`eth_sendRawTransaction` → wait receipt → `getChannel` confirms `deposit == 1000` → sign
voucher (cumulative 500) → build close (FFI) → send → wait receipt → `getChannel` confirms
`finalized == true`.

## Things learned at the live chain
- **`close` finalizes** (`finalized == true`); it does NOT set `settled`. `settled` tracks
  withdrawals (a separate op). Confirmed against mppx's close test, which asserts exactly
  `finalized == true`. (My first assertion checked `settled == 500` and failed though the
  close tx itself succeeded on-chain; corrected to `finalized`.)
- **Fee params:** native gas (`feeToken: nil`) is covered by the abundant faucet grant; no
  TIP-20 fee token needed. `maxFeePerGas = 2 * eth_gasPrice` (20 gwei observed),
  `maxPriorityFeePerGas = 0` (Moderato reports 0), `gasLimit = 2_000_000` (generous; the
  faucet's native balance is effectively unlimited). The attodollar/TIP-20-fee-token path
  is therefore not needed for the e2e.
- **Nonce sequencing** (the #68 Devin note): the builder is stateless and reads the nonce
  per call; the e2e waits for each tx's receipt before building the next, so open=nonce 0,
  close=nonce 1 sequence correctly. A concurrent multi-op client would need its own
  sequencing; out of scope for this proof.

## No production EVMRPC change
`gasPrice` + `transactionCount` + `sendRawTransaction` + `transactionReceipt` + `call`
already existed; the faucet uses `request(...)`. So PR-F adds no production surface, only
the test (+ MPPClient/MPPCore on the FFI test target for URLSessionTransport / JSONValue).

## CI
Added a non-required step to the `rust-ffi` macOS leg (which already builds the xcframework
+ sets MPP_TEMPO_FFI): `MPP_MODERATO_E2E=1 swift test --filter ModeratoE2ETests`. Live +
third-party-dependent like the other Moderato jobs; disable if flaky. Local Docker Linux
compile-check was blocked by daemon instability this session; the CI `linux-ffi` job
compiles the test target on Linux (the e2e skips at runtime there without the env var), and
the existing EVMRPCTests already use URLSessionTransport on Linux CI.

## Verified
Live e2e PASSES against Moderato (real open + close, ~4s), run twice (before + after the
helper refactor). swiftformat / swiftlint --strict / em-dash clean; gated golden suite (5) +
default suite (434) unaffected.

## Remaining in the publish plan
The actual public release cut (a `tempo-tx-ffi-v*` tag + committing the printed constants)
is the only remaining user-gated step; the pipeline (#69) is ready.
