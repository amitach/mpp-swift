# Cross-SDK conformance

This SDK is verified to interoperate with the reference [`mppx`](https://github.com/wevm/mppx)
(TypeScript) implementation over real HTTP, not just against fixed vectors.

## What is covered

The zero-amount `tempo`/`charge` **proof** flow, end to end:

1. The `mppx` server issues a `402` with a `WWW-Authenticate: Payment` challenge
   (`method=tempo`, `intent=charge`, `amount: "0"`, `chainId 42431`).
2. The Swift client (`PaymentClient` + `URLSessionTransport` + `MPPTempo.TempoProofMethod`)
   parses it, builds the default v2 EIP-712 proof credential, and replays with
   `Authorization: Payment`.
3. The `mppx` server verifies the proof (`ecrecover`) and returns `200`.

A pass exercises the whole client vertical: challenge/credential parsing
(`MPPCore`), EIP-712 proof signing (`MPPEVM`), the 402 flow and HTTP transport
(`MPPClient`), and the Tempo proof method (`MPPTempo`).

## How to run

```sh
Scripts/conformance/run.sh            # local self-contained mppx server (no network)
Scripts/conformance/run.sh --testnet  # also probe the live Moderato node (chainId 42431)
```

The Swift test is gated on `MPP_CONFORMANCE_URL`, so it is skipped by the default
`swift test` and by CI; the harness (Node + `mppx`) is never required to build or
test the package. See `Scripts/conformance/README.md` for details.

## Not yet covered

The **settled-transfer** path (non-zero amount) needs the Tempo transaction layer
(`0x76`), which ships in a later workstream. The `--testnet` mode already reaches a
live Moderato node and is the seam for that test when it lands.
