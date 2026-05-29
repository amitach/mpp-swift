# Conformance harness (dev-only)

A reference [`mppx`](https://github.com/wevm/mppx) (TypeScript) server that issues a
zero-amount `tempo`/`charge` 402 and verifies the proof credential, used to prove
the Swift client interoperates with the reference SDK over real HTTP.

This is **dev-only tooling**. Nothing here ships in any product, and the default
`swift test` and CI never touch it: the Swift conformance test is skipped unless
`MPP_CONFORMANCE_URL` is set.

## Run

```sh
Scripts/conformance/run.sh            # local self-contained mppx server (no network)
Scripts/conformance/run.sh --testnet  # also probe the live Moderato node (42431)
```

`run.sh` installs the Node deps, boots `server.mjs`, runs the
`MPP_CONFORMANCE_URL`-gated Swift test (`ConformanceProofTests`) against it, and
tears the server down. A pass means: the Swift client parsed the mppx 402, built
the EIP-712 proof credential, sent `Authorization: Payment`, and mppx verified it
and returned `200 {paid:true}`.

## Modes

- **local** (default): `mppx` configured `testnet: true`, so the challenge carries
  chainId 42431. The proof is verified by `ecrecover` (`verifyTypedData` on an EOA),
  so no Tempo RPC is contacted. Fully offline and deterministic.
- **testnet**: identical proof path, plus a startup `eth_chainId` probe against the
  live Moderato node (`rpc.moderato.tempo.xyz`) to prove reachability. This is the
  seam for the future settled-transfer test (the `0x76` tx layer), which is the only
  thing that needs the real RPC + faucet. Network-dependent, so opt-in only.

## What it proves (and does not)

Proves the full client vertical (challenge/credential parsing, EIP-712 proof
signing, the 402 flow, the URLSession transport, the Tempo proof method) is
byte-compatible with the reference server for the **zero-amount proof**. It does
**not** exercise a settled on-chain transfer (non-zero amount): that path needs the
Tempo transaction layer and lands in a later PR.
