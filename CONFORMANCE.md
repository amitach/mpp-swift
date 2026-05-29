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
Scripts/conformance/run.sh            # forward, local self-contained mppx server (no network)
Scripts/conformance/run.sh --testnet  # forward, also probe the live Moderato node (42431)
Scripts/conformance/run-reverse.sh     # reverse: mppx client pays our Swift server
```

The forward Swift test is gated on `MPP_CONFORMANCE_URL` (skipped by the default
`swift test`); the reverse server is an internal executable target
(`MPPConformanceServer`, no library product). Neither the harness (Node + `mppx`)
nor the reverse server is required to build or test the library. See
`Scripts/conformance/README.md` for details.

## Not yet covered

The **settled-transfer** path (non-zero amount) needs the Tempo transaction layer
(`0x76`), which ships in a later workstream. The `--testnet` mode already reaches a
live Moderato node and is the seam for that test when it lands.
