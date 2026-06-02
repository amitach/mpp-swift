# WS-15 PR-4 security gates + closeout (implementation notes)

Running log. Branch `feat/ws15-security-gates` off `main` (`adadadc`). PR-4 is the WS-15 closeout:
audit every documented security control for test coverage, fill genuine gaps, and record the
conformance / vector / fuzz / security matrix that says the 1.0 bar is met.

## Security-control audit (SECURITY.md §11 + crypto hardening)

Each control in SECURITY.md maps to a type, default, runtime guard, or CI gate. Audited each for a
TEST. Result: 10 of 11 fully covered; the audit surfaced one genuine code gap (control 2, fixed
below) and confirmed the rest. This is the same subtract-before-add outcome as PR-2: prior
workstreams already built the coverage; PR-4 fills only what is genuinely missing.

| # | Control (SECURITY.md) | Verdict | Where |
| - | --------------------- | ------- | ----- |
| 1 | Transport §11.2 (TLS required, non-https rejected, `allowInsecureLocal` loopback-only) | covered | `PaymentClientTests.transportSecurity`, `EVMRPCTests.rejectsInsecure/loopbackOptIn/insecureErrorRedacts` |
| 2 | Credentials §11.2.1 (redacted in description/debugDescription, excluded from errors) | **gap, fixed** | emission-layer redaction tested (`MPPCLITests.credentialLineHasNoSecret`, `EVMRPCTests.insecureErrorRedacts`); type-level key reflection leak found + fixed (below) |
| 3 | Secret management §11.2.2 (rotation + historical-key verify, min/max key length) | covered | `FileSecretLoaderTests`/`EnvironmentSecretLoaderTests.loadsPreviousKeys/shortKeySurfacesValidation` |
| 4 | Replay §11.3 / idempotency §11.4 (single-use, consumed before side effects) | covered | `PaymentVerifierTests.rejectsReplay/invalidCredentialDoesNotConsume/concurrentSingleVerification` |
| 5 | Amount §11.6 (integer base units, approval before signing, no Double/Float) | covered | `AmountTests.*`, `TempoChannelMethodTests.approvalDenied/approvalFactsDecodes` |
| 6 | Caching §11.10 / DoS §11.12 (`no-store` on 402, `private` on receipted 200, 413 body cap) | covered | `MPPServerMiddlewareTests.http402/http200Receipted/http413/bodyCap/handlerWeakerCacheControlRaisedToFloor` |
| 7 | RFC 6979 deterministic nonces | covered | `Secp256k1SignerTests.deterministic/goldenVector` |
| 8 | Malleability / recover bounds (low-s, 65-byte `r\|\|s\|\|v`, `v` in 27...30, rejects malformed) | covered | `Secp256k1SignerTests.recoverRejectsBadRecoveryID/recoverRejectsShortCompact/signatureInitValidates`, `EIP712ProofTests.recoverMalformed` |
| 9 | Keccak-256 known-answer vector | covered | `Keccak256Tests.empty` (`keccak256("") = 0xc5d2460...a470`) |
| 10 | EIP-712 (`0x19 0x01`, domain binds chainId + verifyingContract, byte-for-byte vs viem) | covered | `EIP712ProofTests.proofV2/proofV1/variantsDiffer`, `VoucherTests.voucherMatchesViem` |
| 11 | Constant-time comparison (MAC/digest/secret) | covered | `ChallengeSigner.verify` uses swift-crypto `isValidAuthenticationCode` (constant-time); `ChallengeSignerTests.rejectsWrongSecret` |

## Genuine gap found + fixed: private-key reflection leak (control 2)

`Secp256k1Signer` stored its key as `privateKey: [UInt8]`. Unlike `Data` (whose `description` is
`"<n> bytes"`, the convention `SecretStore` and `ChallengeSigner` rely on), an array's default
reflection prints the raw byte values, so `String(describing: signer)` rendered
`Secp256k1Signer(privateKey: [171, 171, ...], ...)`, exposing the private key. SECURITY.md §11.2.1
and the crypto-hardening section both promise signing keys never appear in a description, log, or
trace, so this was a real (if low-likelihood) leak, verified empirically before the fix.

Fix (additive, no change to signing logic): `Secp256k1Signer` now conforms to
`CustomStringConvertible` + `CustomDebugStringConvertible`, rendering only the non-secret public key
(`Secp256k1Signer(publicKey: 0x...)`). `debugDescription` is included because string interpolation
and most logging use it.

Tests:
- `Secp256k1SignerTests.redactsPrivateKey`: `description`/`debugDescription`/`"\(signer)"` never
  contain the raw key (a `0xAB` key would reflect as `[171, 171, ...]`; that run cannot appear in the
  public key's hex), and do show the public key.
- `ChallengeSignerTests.secretIsNotReflected`: a regression guard pinning that `ChallengeSigner` and
  `SecretStore` (both `Data`-backed) do not leak the secret via reflection, so a future refactor to
  a byte array (the exact bug class found above) fails here.

## Documented hardening items (not fixed here)

**Mirror / dump reflection path.** The redaction above (and `Data`'s `"<n> bytes"` description) covers
the §11.2.1 surfaces: `description`/`debugDescription`, hence string interpolation, `print`,
`String(describing:)`, errors, and logs. The explicit debug-only reflection path (`dump(x)` /
`Mirror(reflecting: x).children`) still enumerates raw secret bytes for EVERY reflectable secret type,
`Data`-backed ones included (verified: `Data`'s deep mirror exposes its `bytes`). This is outside
§11.2.1's logging/error/trace threat model (no production code calls `dump`/`Mirror`), so a
`CustomReflectable` pass across the secret-holding types is recorded as a uniform defense-in-depth
follow-up rather than gold-plating a debug API in this closeout.

**Credential type-level description.** `Credential` has no type-level redacting description, so
`String(describing: credential)` would
reflect its `payload` (the method-specific proof, e.g. a signature). This is lower severity than a
key: the proof is single-use and already crosses the wire to the server, and credential redaction is
enforced and tested at the layers that actually emit (`MPPCLITests`, `EVMRPCTests`). A type-level
redacting `CustomStringConvertible` on `Credential` is recorded as a defense-in-depth hardening item
(in the style of SECURITY.md's deferred EIP-2 `s <= n/2` note), not done in this closeout to avoid
changing a public value type's behavior without an explicit ask. Hard memory zeroization of Swift
value-type copies is scoped out by SECURITY.md itself (impossible for value types; only raw buffers
the SDK fully controls are zeroized).

## WS-15 workstream summary (the 1.0 conformance / vector / fuzz / security bar)

- **PR-1 (#119) parser fuzz parity:** curated deterministic adversarial corpus + round-trip for
  Challenge/Credential/Receipt and the SSE/WS stream codecs (no-trap on hostile input).
- **PR-2 (#120) vector / test-parity sweep:** G7.5 audit found the planned surfaces already covered;
  filled the 2 real gaps (Receipt cross-SDK golden bytes, voucher malformed-signature rejection).
- **PR-3 (#121) MPPProxy cross-SDK conformance:** an mppx client pays a route THROUGH our proxy
  (`run-proxy.sh` + a CI step), proving the proxy verifies a foreign credential and forwards.
- **PR-4 (this) security gates + closeout:** audited all 11 §11 + crypto controls; fixed the
  private-key reflection leak; recorded this matrix.

## Verification

- `swiftformat` clean; `swiftlint --strict` 0 violations; repo-wide em-dash check clean.
- New + affected suites (Secp256k1Signer + ChallengeSigner): 20 tests / 2 suites pass, including the
  two new redaction/reflection tests. Full CI matrix (macOS + Linux + Lint + FFI + conformance +
  Devin) is the merge gate.
