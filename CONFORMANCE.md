# Cross-SDK conformance

This SDK is verified to interoperate with the reference [`mppx`](https://github.com/wevm/mppx)
(TypeScript) implementation over real HTTP, not just against fixed vectors, in
**both directions** of the zero-amount `tempo`/`charge` **proof** flow.

## Forward: our client pays the mppx server

1. The `mppx` server issues a `402` with a `WWW-Authenticate: Payment` challenge
   (`method=tempo`, `intent=charge`, `amount: "0"`, `chainId 42431`).
2. The Swift client (`PaymentClient` + `URLSessionTransport` + `MPPTempo.TempoProofMethod`)
   parses it, builds the default v2 EIP-712 proof credential, and replays with
   `Authorization: Payment`.
3. The `mppx` server verifies the proof (`ecrecover`) and returns `200`.

Exercises the whole client vertical: `MPPCore` (challenge/credential), `MPPEVM`
(proof signing), `MPPClient` (the 402 flow + transport), `MPPTempo` (the method).

## Reverse: the mppx client pays our server

1. Our Swift server (`MPPConformanceServer`, a dev-only HTTP listener backed by
   `MPPServerMiddleware` + `MPPTempoServer.TempoProofVerifier`) issues the `402`.
2. The reference `mppx` **client** signs the zero-amount proof and retries.
3. Our `TempoProofVerifier` verifies it (`ecrecover`, source pinned) and returns `200`.

Exercises the server vertical against a FOREIGN client: `MPPServer` (mint/verify/
middleware) and `MPPTempoServer` (the proof verifier).

## How to run

```sh
Scripts/conformance/run.sh            # forward proof, local self-contained mppx server (no network)
Scripts/conformance/run.sh --testnet  # forward proof, also probe the live Moderato node (42431)
Scripts/conformance/run-reverse.sh     # reverse proof: mppx client pays our Swift server
Scripts/conformance/run-session.sh         # forward CHANNEL: our client open/voucher/close vs the mppx session server (live)
Scripts/conformance/run-session-reverse.sh # reverse CHANNEL: mppx client open/voucher/close vs our SessionMethod server (live)
```

The forward Swift test is gated on `MPP_CONFORMANCE_URL` (skipped by the default
`swift test`); the reverse server is an internal executable target
(`MPPConformanceServer`, no library product). Neither the harness (Node + `mppx`)
nor the reverse server is required to build or test the library. See
`Scripts/conformance/README.md` for details.

## Channel sessions (settled, non-zero, live on Moderato)

The non-zero **payment-channel** path is verified in BOTH directions against the reference
`mppx`, live on the Moderato testnet (chainId 42431), faucet-funded and self-contained:

- **Forward** (`run-session.sh`): our `TempoChannelMethod` (client) opens a channel against
  the `mppx` **session server**, vouchers, and closes; the `mppx` operator settles our voucher
  on-chain (the channel finalizes). Exercises the client vertical + the `0x76` open builder.
- **Reverse** (`run-session-reverse.sh`): the `mppx` **client** opens a channel against our
  `MPPConformanceServer` `/session` route (`MPPTempoServer.SessionMethod` +
  `RPCChannelStateProvider`), vouchers, and closes; our server relays the open on-chain,
  accepts the voucher, and settles the close with a faucet-funded operator.

Both are gated on `MPP_TEMPO_FFI` (the session open/close needs the `0x76` builder) and are
live (depend on the Moderato node + faucet), so they run in the non-required `rust-ffi`
macOS CI job, not the default `swift test`. The session server route is compiled only under
the FFI gate; the default reverse server stays proof-only and Rust-free.

The off-chain proof flow (above) stays offline and deterministic; only the channel/settle
flow touches the chain.
