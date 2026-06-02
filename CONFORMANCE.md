# Cross-SDK conformance

This SDK is verified to interoperate with the reference [`mppx`](https://github.com/wevm/mppx)
(TypeScript) implementation over real transports, not just against fixed vectors, in **both
directions** across every flow that has a reference peer: the zero-amount `tempo`/`charge`
**proof**, the settled payment-**channel** session, **subscription** activation + on-chain renewal,
the metered **streaming** codecs (SSE + WebSocket), the **JSON-RPC / MCP** payment binding, the
**Stripe** rail (live-verified), and the shipped **`mpp` CLI** binary. Each is detailed below.

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
Scripts/conformance/run-mcp.sh                  # forward MCP: the mppx mcp-sdk client pays our Swift MCP server (stdio)
Scripts/conformance/run-mcp-reverse.sh          # reverse MCP: our Swift MCP client pays the mppx mcp-sdk server (stdio)
Scripts/conformance/run-cli.sh                  # CLI: the shipped `mpp` binary pays the mppx server over real HTTP
Scripts/conformance/run-stripe-live.sh           # Stripe, LIVE: a real test-mode PaymentIntent (preview + secret gated)
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

## Live WebSocket transport (metered session over a real socket)

Beyond the codec parity above, the live `MPPWebSocket` / `MPPWebSocketLive` transport is exercised
over a real `ws://` socket by `MPPWebSocketLiveTests`: a live Hummingbird WebSocket server (our
server adapter) and our client adapter run a full metered session end to end (authorization ->
payment-receipt -> message chunks -> payment-close-ready). Gated on `MPP_WS_LIVE` and run isolated on
the **Linux** CI job + local macOS dev (the GitHub macOS runner cannot reliably bind a localhost
WebSocket listener via NIOTransportServices); the deterministic in-process `MPPWebSocket` suites are
the required gate on both platforms.

A standalone *cross-SDK* live ws session against the `mppx` ws server is deliberately **not** built:
it rides the on-chain channel rail, so it would re-prove a composition already proven (the codec
parity above + this live self round-trip + the on-chain channel that `run-session.sh` already proves
cross-SDK against the same `mppx` server), with only the socket framing swapped.

## JSON-RPC / MCP transport (both directions, stdio)

The `MPPMCP` payment binding is verified against the reference `mppx` `mcp-sdk` over a real stdio
transport, both directions, offline (a zero-amount proof, no chain):

- **Forward** (`run-mcp.sh`): the `mppx` `mcp-sdk` **client** calls a payment-gated tool on our
  `MPPMCPConformanceServer` (`MPPMCP` gate over `MPPServerMiddleware`), reads the `-32042` frame +
  challenge, pays via `params._meta`, and reads the receipt from `result._meta`.
- **Reverse** (`run-mcp-reverse.sh`): our Swift `MCPPaymentClient` pays the `mppx` `mcp-sdk`
  **server** (reads its `-32042`, builds the credential, reads its receipt).

Both run in the required `Conformance (local)` CI job (offline + deterministic).

## CLI (the shipped `mpp` binary)

`run-cli.sh` drives the **installed artifact**, not just the in-process library: it boots the same
`mppx` reference server and runs the built `mpp` binary against it over real HTTP
(`mpp pay <url> --approve auto --max-amount 0 --insecure --json` settles a zero-amount proof: exit
0, `status:200`, `ok:true`, a receipt reference), and asserts the curl-like fail-closed exit-code
contract (no key -> exit 69). Offline; runs in the required `Conformance (local)` CI job.

## Stripe rail

The `MPPStripeServer` charge path is conformance-checked at two levels. **Offline:** `StripeChargeVerifier`
maps a Shared Payment Token credential to a PaymentIntent via an injected seam (stubbed, no account),
covering status -> receipt/reject, Connect parity, and validation, in the default suite.
**Live (`run-stripe-live.sh`):** a real `sk_test` settles a real test-mode PaymentIntent against
`api.stripe.com` through `StripePaymentIntentClient`; preview + secret gated (`STRIPE_TEST_SK`), the
test self-skips when the key is absent, so it runs only in the non-required `stripe-live` CI job.
