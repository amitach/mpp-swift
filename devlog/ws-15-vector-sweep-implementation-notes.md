# WS-15 PR-2 vector / test-parity sweep (implementation notes)

Running log. Branch `feat/ws15-vector-sweep` off `main` (`adadadc`). WS-15 PR-2 is the G7.5
test-parity sweep: mine the reference SDK's per-module tests for edge-case vectors and port the
genuine gaps (the union approach), citing the spec, mining peers internally only.

## G7.5 sweep outcome: planned scope already covered

The plan teed PR-2 up to add discovery 3.0/3.1, amount:null, voucher-envelope rejections, and proof
v1/v2 vectors. Auditing each surface against our existing suites shows prior WS PRs already cover the
union of the reference per-module tests (this is the gate working: confirm coverage, port only real
gaps). Per surface:

- **Discovery** (`DiscoveryTests` 24 + `DiscoveryGenerateTests` 8): version acceptance 3.0.x/3.1.x and
  rejection of bad suffixes; amount:null to dynamic, fixed, and absent forms; flat-vs-offers
  normalization; empty/mixed offers rejection; bad-amount "01"; custom intents; missing info; the
  402-required error and requestBody warning; doc-link validation; service info. Covered, plus more.
- **Proof v1/v2** (`TempoProofMethodTests`): v2 byte-exact, v1 wallet, spec single-field, chainId
  fallback/override, non-canonical amount rejection, wrong method/intent. Covered.
- **DID / proofSource parse rejections** (`ProofSourceTests.rejectsMalformed`): leading-zero chainId,
  empty chainId, bad address, trailing junk, wrong prefix, u64 overflow, non-numeric, extra colon, no
  chainId segment. Covered, plus a documented reasoned deviation (we accept chainId > 2^53 across the
  full u64 range; the reference caps at the JS safe-integer range).
- **Voucher-envelope rejections** (`VoucherTests`): magic-suffixed, keychain-envelope, wrong
  signer/amount/channel, domain binding (chainId/escrow), uint128 bounds. Covered, plus more.
- **Amount** (`AmountTests`): canonical integers, empty, decimal, non-digit, leading-zero, numeric
  ordering. Covered.
- **Errors to ProblemDetails URIs** (`MPPServerMiddlewareTests`): pins the
  `paymentauth.org/problems/*` type URIs for payment-required / malformed-credential /
  invalid-challenge / verification-failed / payment-expired. Covered.
- **PaymentRequest decimal normalization** (reference `amount:'1'` + `decimals:6` to `'1000000'`):
  N/A by design. We have no decimal-to-base-units helper; `Amount` enforces canonical base-units on
  the wire and human-decimal input is a separate charge-layer concern. Nothing to port.

## Genuine gaps filled (lean PR, user-confirmed scope)

Only two genuine peer-parity gaps remained. Both filled in their existing test homes (no new files,
G3.6):

1. **Receipt exact cross-SDK golden bytes** (`Tests/MPPCoreTests/ReceiptTests.crossSDKGoldenVector`):
   we tested canonical encoding self-consistently but never pinned a fixed external wire vector as a
   shared oracle. Added a base64url(JSON) Payment-Receipt vector and assert BOTH directions: we
   consume the exact bytes (decode to the expected fields) and we produce the exact bytes
   (`headerValue` equals the literal). Verified the sorted-key encoder is byte-identical and that
   `RFC3339DateTime` preserves a fractional-second `...000Z` timestamp through the round-trip. This
   is the strongest cross-SDK guarantee short of a live round-trip (a shared byte oracle).
2. **Voucher malformed-signature rejection**
   (`Tests/MPPEVMTests/VoucherTests.verifyRejectsMalformedSignature`): we rejected magic-suffixed and
   keychain-envelope and mismatched signatures, but not a malformed BARE signature (empty, 4-byte,
   64-byte). `Voucher.verify` delegates to `EthereumAddress.recover`, which guards `count == 65`
   before indexing, so it already fails closed (returns false) and never traps; the test pins that.

## Verification

- `swiftformat` clean; `swiftlint --strict` 0 violations; repo-wide em-dash check clean.
- Affected suites (Receipt + Voucher across targets): 40 tests / 18 suites pass, including the new
  byte-exact Receipt golden (both directions) and the malformed-signature rejection.
- Full CI matrix (macOS + Linux + Lint + FFI + conformance + Devin) is the merge gate.
