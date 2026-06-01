# Cross-SDK conformance

This SDK is verified to interoperate with the reference [`mppx`](https://github.com/wevm/mppx)
(TypeScript) implementation over real HTTP, not just against fixed vectors, in **both directions**
across every implemented Tempo flow: the zero-amount `tempo`/`charge` **proof**, the settled
payment-**channel** session, **subscription** activation (key authorization), and the metered
**streaming** codecs (SSE + WebSocket). Each is detailed below.

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
Scripts/conformance/run-subscription.sh         # forward SUBSCRIPTION: our client signs a key-auth vs the mppx subscription server (offline)
Scripts/conformance/run-subscription-reverse.sh # reverse SUBSCRIPTION: mppx client signs a key-auth vs our TempoSubscriptionVerifier (offline)
Scripts/conformance/run-subscription-live.sh     # reverse SUBSCRIPTION, LIVE: mppx client activates vs our server, which settles period 0 on-chain (Moderato)
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

## Subscriptions (key authorization + on-chain renewal, both directions)

The `tempo`/`subscription` flow is verified against `mppx` at two levels: **activation** (signing the
`TempoKeyAuthorization`, offline in both directions) and **on-chain renewal** (our server settling a
recurring charge live on Moderato).

**Activation (offline, both directions).** Activation signs no on-chain transaction (it grants a
`TempoKeyAuthorization`), so it is fully offline (no faucet, RPC, or testnet), deterministic and cheap.

- **Forward** (`run-subscription.sh`): our `TempoSubscriptionMethod` (client) signs the key
  authorization delegating the access key the `mppx` **subscription server** issued in its 402, and
  the `mppx` server's verifier accepts it. Proves our signed `TempoKeyAuthorization` bytes are
  accepted by the reference verifier.
- **Reverse** (`run-subscription-reverse.sh`): the `mppx` **client** signs a key authorization
  against our `MPPConformanceServer` `/subscription` route (`MPPTempoServer.TempoSubscriptionVerifier`),
  and our re-encode-and-compare verifier accepts it.

Gated on `MPP_CONFORMANCE_SUBSCRIPTION_URL` (forward) / run as an internal executable (reverse); the
`/subscription` route is un-gated (offline) so it runs in the standard `Conformance (local)` CI job.

**On-chain renewal (live on Moderato).** `run-subscription-live.sh` proves the full recurring charge,
not just the signature: the `mppx` **client** activates a subscription against our `/subscription-live`
route, and our `TempoSubscriptionRenewer` immediately settles period 0 on-chain (charge-on-activate) by
submitting the recurring `transferWithMemo` the key authorization permits, signed by the server-held
access key (`AccessKeyStore`) as a Tempo V2 keychain signature on behalf of the payer (root). A PASS
means the `mppx` client's authorization was accepted **and** our charge mined successfully.

The charge is **gas-sponsored**: the chain meters gas against the access key's per-period spending
limit in addition to the transfer, and both SDKs set that limit to the charge amount, so a fee payer
(a faucet-funded gas sponsor) signs the transaction's fee-payer signature and pays gas, leaving the
limit to cover only the transfer. The route is opt-in (gated on `CONFORMANCE_FEE_PAYER_KEY`, which the
harness funds before boot) and FFI-gated (the charge needs the `0x76` builder), so it runs in the
non-required live CI job alongside the channel-session live conformance, not the default `swift test`.

## Metered streaming codecs (SSE + WebSocket)

`ConformanceStreamCodecTests` pins the streaming wire formats: our `SessionStreamEvent` (SSE) and
`SessionWebSocketFrame` (WebSocket) parsers accept the **exact bytes** the reference `mppx`
formatters emit (golden vectors captured from `mppx` `session/Sse.js` + `session/Ws.js`). The reverse
direction (`mppx`'s own `parseEvent` / `parseMessage` accept our output) was verified directly
against those parsers. Hermetic (no server), part of the default suite.
