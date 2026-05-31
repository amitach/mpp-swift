# Subscriptions + metered streaming (WS-10 B6 + WS-9) - implementation notes

Combined, rail-neutral workstream. Plan: `~/.claude/plans/mpp-swift-subscriptions-streaming-plan.html`.
Peer: mppx `tempo/subscription`, `tempo/session/{Sse,Ws}`, `stripe/` (sole peer; cite the spec in
shipped code). Confirmed decisions: KeyAuthorization = pure Swift in MPPEVM (not FFI); full scope
(protocol + store + renewal engine); SSE + WebSocket both in; Stripe = prove-only seam this run
(real MPPStripe is WS-11 later, user chose (a)).

Phased PRs: PR-1 key-auth primitive / PR-2 protocol core + activation / PR-3 store + renewal engine /
PR-4 streaming core + SSE / PR-5 WebSocket. See the plan HTML for the per-PR checklists.

## Reuse audit (verify-before-build, per feedback_verify_exists_before_building)

Before writing PR-1 the signature side was checked and found to ALREADY exist; the user caught the
near-duplication ("we don't have that already?"). Confirmed reused, NOT rebuilt:
- `Secp256k1Signer.sign(hash:)` -> RecoverableSignature (compact 64 + recoveryID).
- the Voucher 65-byte pattern `compact + Data([recoveryID + 27])` = the secp256k1 SignatureEnvelope
  (ox treats a bare 65-byte value as secp256k1; no typed envelope needed for our path).
- `EthereumAddress.recover(hash:signature:)` (ecrecover), `Keccak256.hash`, `EIP712.uint256(_:)` +
  `EIP712.uint256(decimal:)` (32-byte words; strip leading zeros for RLP minimal integers).
So PR-1's only genuinely-new code is a pure-Swift RLP codec + the KeyAuthorization tuple builder.

## PR-1 - TempoKeyAuthorization (DONE, branch feat/tempo-keyauth)

- `Sources/MPPEVM/RLP.swift`: minimal canonical RLP encode + decode (bytes/list), typed throws.
- `Sources/MPPEVM/TempoKeyAuthorization.swift`: the struct + the inner tuple
  `[chainId, type, address, expiry, limits, calls]` (targets the subscription shape: limits + scopes
  always present), `signPayload()` = `keccak256(RLP(tuple))`, `serialize(signature:)`,
  `sign(with:)` (65-byte secp256k1 envelope), `signedSerialization(with:)`, `deserialize` (full field
  round-trip), `recover(serialized:)`. secp256k1 only (p256/webAuthn tuple bytes encode but aren't
  signed here). limit amount = uint256 decimal string; bytes<->decimal via EIP712.uint256(decimal:)
  + an inverse base-256->base-10 helper.
- KEY FORMAT FACTS (from ox/tempo, verified): type byte is EMPTY for secp256k1 (`0x`), `0x01` p256,
  `0x02` webAuthn; integers are minimal big-endian (0 -> empty); a limit's `period` is omitted when 0;
  scopes are grouped by address: `[address, [[selector, [recipients...]]]]`; `getSignPayload` hashes
  the INNER tuple only (not the [tuple, sig] wrapper); transferWithMemo selector = `0x95777d59`.
- Tests (`Tests/MPPEVMTests/TempoKeyAuthorizationTests.swift`): 8, all green. **Golden vectors
  captured from `ox/tempo`** (a subscription-shaped auth signed with privkey 0x..01): unsigned RLP,
  sign payload, and the **deterministic signed serialization match BYTE-FOR-BYTE** (proves our RLP +
  keccak + RFC-6979 secp256k1 == the reference); recover -> signer address; deserialize round-trip;
  unsigned-has-no-signature; recover rejects unsigned/malformed; tamper changes the payload.
- Golden generator (throwaway, not committed): a node script using `ox/tempo` KeyAuthorization +
  SignatureEnvelope + ox Secp256k1, run from Scripts/conformance (where `ox` resolves).
- Lint: golden hex literals exceed line_length; the repo has NO `swiftlint:disable line_length`
  precedent, so the shared inner tuple + signature are defined once, chunked, and composed (DRY +
  no risk of corrupting a vector). swiftformat + swiftlint --strict clean.

### Gates applied (PR-1)

- **G6/G7 (security/adversarial):** the RLP decoder parses attacker-supplied bytes (a server decoding
  a client credential), so it is depth-bounded (`RLP.maxDepth = 64`, the same stack-exhaustion class
  as the MCP bridge fix) and rejects non-canonical / overflowing lengths. `RLPTests` covers
  over-deep nesting, truncation, leading-zero + Int-overflow lengths, and trailing bytes.
- **G7.5 (peer test-parity):** mined `ox/tempo/KeyAuthorization.test.ts` + mppx
  `subscription/KeyAuthorization.test.ts`; ported the genuine PR-1 gaps (multi-limit byte golden,
  zero-expiry + zero-chainId empty-integer round-trips, empty-keyType => secp256k1). DEFERRED to PR-2
  / out of secp256k1 scope: verify-against-request cases (wrong access key, requires-transferWithMemo,
  period/expiry representability) and p256/webAuthn signing.
- **G3.5:** code/tests cite the spec (Tempo Access Keys + Ethereum RLP), not the peer; the peer
  reconciliation lives here in the devlog only.
- **G3.6:** removed a never-thrown `AuthorizationError.missingSignature` and an unreachable
  `byteCount <= 8` RLP guard (the prefix range caps it at 8; the real guard is `length >= 0`).
- **G1:** macOS green locally; pure Foundation + existing MPPEVM, no Darwin-only API, so Linux is
  expected green on CI (the required matrix will confirm before merge).

## Deviations / open

- The tuple builder targets the subscription shape (always emits expiry+limits+calls). A fully
  general KeyAuthorization (ox omits expiry/limits/calls conditionally when absent) is not needed
  yet; documented in the type doc. Revisit only if a non-subscription key-auth consumer appears.
