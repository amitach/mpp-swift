# On-chain subscription renewer: implementation notes

> Follow-up #1 from the subscription rail. Plan: ~/.claude/plans/mpp-swift-subscription-renewer-plan.html
> (5 PRs). This devlog tracks PR-1: the FFI charge-tx builder + Rust tests + Swift seam.

## Verified mechanism (crate 8b80b16 + peer mppx@0.6.28)

The recurring charge is a plain `0x76` `TempoTransaction` with one call
`transferWithMemo(recipient, amount, memo)` on the TIP-20 currency, signed by the access key.
The payer-signed key authorization rides in `TempoTransaction.key_authorization:
Option<SignedKeyAuthorization>` (provisions the access key into the AccountKeychain precompile,
~4M gas). First charge attaches it; later charges omit it. Peer: `submitSubscriptionPayment`.

## PR-1 decisions / findings

- **Reuse `build_signed_tx`.** Add a `key_authorization: Option<SignedKeyAuthorization>` param to
  the existing private `build_signed_tx` and set it on the `TempoTransaction`; the 3 existing
  builders (open/topUp/close) pass `None`. One tx-assembly path, no duplication.
- **WIRE COMPAT (the subtle bit).** Our Swift serialized authorization is
  `RLP([innerTuple, 65-byte r‖s‖v])`. The crate's `SignedKeyAuthorization` is
  `{ authorization: KeyAuthorization, signature: PrimitiveSignature }` with a *derived* RLP, so the
  signature field is encoded structurally, NOT as a 65-byte blob. So `SignedKeyAuthorization::decode`
  does NOT accept our wire form. The FFI decodes robustly instead: split the outer RLP list, decode
  the inner tuple via `KeyAuthorization::decode` (already proven byte-identical to our Swift encoder
  by the existing differential test), build `PrimitiveSignature` from the 65 bytes (r‖s‖v, v=recid+27),
  then `authorization.into_signed(sig)`. The offline conformance only exercised the inner-tuple
  re-encode; this signed-wrapper-on-a-tx path is new and gets its own Rust test + (PR-5) live proof.
- **FFI surface:** new typed `build_subscription_charge_tx` + UniFFI export
  `build_subscription_charge_transaction` (Option<Vec<u8>> serialized authorization, decimal-String
  amount, 32-byte memo). Mirrors the existing 3 exports' validation helpers.
- **Swift seam:** `TempoSubscriptionChargeTxBuilder` protocol in MPPTempo (sibling of
  TempoOpenTxBuilder), un-gated. The concrete conformer is a SEPARATE `FFISubscriptionChargeTxBuilder`
  (not `FFITempoTxBuilder`): the signing key is the access key, which differs per subscription and
  arrives per charge in the params, so it holds only fee + nonceProvider rather than a single held
  key. FFI pulled only when injected.

## PR-1 progress (Rust FFI core: DONE, green)

- `transferWithMemo(address,uint256,bytes32)` added to the `sol!` block; new typed
  `build_subscription_charge_tx` + UniFFI export `build_subscription_charge_transaction`.
- `build_signed_tx` gained an `Option<SignedKeyAuthorization>` param (3 existing builders pass
  `None`); set on `TempoTransaction.key_authorization`.
- **Finding: `into_signed` wants tempo's `transaction::PrimitiveSignature` enum, NOT alloy's
  `Signature`.** Wrap as `PrimitiveSignature::Secp256k1(Signature::try_from(&65bytes))`. (alloy
  1.6.0 dropped the `PrimitiveSignature` alias; the type at the root is `Signature`.)
- **`alloy-rlp` moved from `[dev-dependencies]` to `[dependencies]`** (the decode helper is in the
  main lib now, not just tests).
- **Peer-pinned test (per the always-verify-peer rule):** generated the golden signed
  authorization with ox/tempo `KeyAuthorization.serialize` (mppx's serializer) over the shim's
  existing golden authorization, signed by root key `0x..01`. Its inner tuple is byte-identical to
  the shim's `INNER_TUPLE`; trailing `b841..` = the 65-byte sig. The FFI decode round-trips it and
  recovers `0x7e5f4552091a69125d5dfcb7b8c2659029395bdf` (account #1). Pinned as
  `PEER_GOLDEN_SIGNED_AUTH`. Vector provenance: `npm pack mppx@0.6.28` + ox/tempo. This confirms the
  signed-wrapper wire compat the offline conformance never exercised.
- `cargo test` 10/10, `cargo fmt --check` clean, `cargo clippy` clean.

### Remaining PR-1 piece
- Swift seam `TempoSubscriptionChargeTxBuilder` (MPPTempo) + `FFITempoTxBuilder` conformance + the
  wrapper over the generated `build_subscription_charge_transaction`. Needs the UniFFI bindings
  regenerated (the FFI build / `MPP_TEMPO_FFI=1`), which CI does from source. Then it is the export's
  Swift caller (satisfies the no-zero-caller gate).

## PR-2 (Attribution memo): DONE

- `Attribution.encode(serverId:challengeId:clientId:)` in MPPTempo, reusing `Keccak256` (MPPEVM):
  32-byte memo = tag `keccak256("mpp")[0..3]` + version `0x01` + serverId fingerprint
  `keccak256(serverId)[0..9]` + clientId fingerprint (or 10 zero bytes) + nonce
  `keccak256(challengeId)[0..6]`. Pure Swift, no FFI, no release.
- Peer-pinned: vectors generated from mppx@0.6.28's own `Attribution.encode` (imported from its dist
  via file URL; not a public export) - tag `0xef1ed712`, the server-only and with-client memos.
  The Swift keccak reproduces them byte-for-byte (6 tests). Cite the Tempo attribution-memo spec, not
  the peer, in shipped doc.
- No production caller yet; the renewer (PR-4) consumes it (the plan sequences it as the consumer).

## PR-3 (AccessKeyStore + access-key private-key seam): DONE

- `AccessKeyStore` protocol + `InMemoryAccessKeyStore` actor in MPPTempoServer (mirrors
  SubscriptionStore/ChannelStore), keyed by `lookupKey` like the peer's `store.getAccessKey`.
  `provision(forLookupKey:)` generates-or-gets a keypair (idempotent) and returns the address to
  embed in the 402; `privateKey(forLookupKey:)` returns it for renewal signing. Keypair = 32
  system-RNG bytes (injectable generator, like the saltProvider pattern), Secp256k1Signer,
  EthereumAddress; provision is a synchronous actor method (no await inside), so it is atomic and
  concurrent first-uses mint exactly one key.
- Wired into the dev MPPConformanceServer subscription middleware: provisions the access key and
  embeds `accessKeyAddress.checksummed` in the 402, replacing the hardcoded hex (the real caller for
  the subtraction gate; made `makeSubscriptionMiddleware` async). The offline reverse conformance
  only verifies (privateKey unused there; the renewer PR-4 is its consumer).
- **Security (self-review):** holds spendable secp256k1 private keys at rest; in-memory impl is
  test-only; never log key material (provision returns the address, the key only via the explicit
  accessor). Doc made honest: the seam returns raw key bytes because the renewal FFI signs with them,
  so it fits an OS-keychain/KMS-backed store that returns the key for the FFI to zeroize; a fully
  NON-EXPORTING HSM would need a signing-delegation seam (a follow-up), not key export. Deterministic
  test pins private key 1 to account #1's address.

## PR-4 (TempoSubscriptionRenewer): DONE

- `TempoSubscriptionRenewer: SubscriptionRenewer` (MPPTempoServer) ties the vertical together behind
  injected seams: `AccessKeyStore.privateKey(forLookupKey:)` for the signing key, `Attribution.encode`
  for the memo, a `TempoSubscriptionChargeTxBuilder` for the signed tx, and a `submit` closure
  (`@Sendable (Data) -> TransactionReceipt`, production passes `EVMRPC.sendRawTransactionSync`).
- `charge(record, period, idempotencyReference)`: resolve the access key (else `accessKeyMissing`);
  attach the authorization iff `record.lastChargedPeriod == nil` (the provisioning charge; later
  charges omit it, matching our nil-default activation); memo from the idempotencyReference; build +
  submit; `succeeded == false` -> `chargeReverted(hash)` so the engine releases its claim; return the
  tx hash. `period` is unused directly (it is encoded in the idempotencyReference, like the peer's
  settlementReference).
- DECISION: provisioning inferred from `lastChargedPeriod == nil` rather than a new
  `accessKeyProvisioned` record field (subtract-before-add; keeps the rail-agnostic engine + record
  unchanged). Correct for our activation model (verifier does not settle period 0); documented.
- No new FFI function (consumes PR-1's `build_subscription_charge_transaction`), so NO release.
- Tests (5, hermetic): first charge attaches auth + correct currency/recipient/amount/memo/chain +
  the stored key; later charge omits auth; revert throws; missing key throws; end-to-end through
  SubscriptionEngine (activate -> renew -> .renewed, record advances, first charge provisions).

## PR-5 (live Moderato e2e): DONE, and it found a real on-chain bug

- New gated e2e (`MPP_MODERATO_E2E=1`): fund a payer (root), sign a real `TempoKeyAuthorization`
  delegating a fresh access key, run `TempoSubscriptionRenewer` twice (provision+charge, then a plain
  charge), assert the recipient's TIP-20 balance grows by the amount each time. Self-contained via the
  faucet. MPPTempoServer added to the MPPTempoFFITests target deps. Runnable locally (the Moderato RPC
  + faucet are public); iterated live.
- **KEY FINDING (the whole point of a live e2e): the charge tx needs a Tempo V2 KEYCHAIN signature,
  not a plain signature.** The chain rejected the plain-signed tx: "KeyAuthorization must be signed by
  root account X, but was signed by Y" - a plain signature makes the tx SIGNER the root, but an access
  key signs ON BEHALF OF the root via a `KeychainSignature{user_address: root}` (V2: the access key
  signs `keccak256(0x04 || sig_hash || user_address)`). PR-1's builder produced a plain signature -
  self-consistent in the hermetic goldens but on-chain-invalid. FIX (this PR): `build_signed_tx` gained
  `Option<Address> keychain_user_address`; the subscription builder passes `Some(root)`, signs the
  keychain hash, wraps `TempoSignature::Keychain(KeychainSignature::new(root, Secp256k1(sig)))`; the
  channel builders pass `None` (unchanged). `TempoSubscriptionChargeParameters` + the renewer now carry
  `payer` (the root); the nonce is the payer's (the executing account), not the access key's.
- The FFI signature changed (added `root_address`), so this needs a new release: cut
  **tempo-tx-ffi-v0.0.4** + bump the Package.swift constants (same dance as v0.0.2/v0.0.3). Updated the
  Rust + Swift charge goldens (now keychain-signed: trailing `b856 04 <root> <65-byte sig>`).
- Verified LIVE on Moderato: both charges settle, the recipient balance grows each period; hermetic
  FFI 24/24 + renewer/store green; lint + em-dash clean.

THE ON-CHAIN SUBSCRIPTION RENEWER VERTICAL IS COMPLETE (PR-1..PR-5).
