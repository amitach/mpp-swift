# WS-15 PR-1: parser fuzz parity (implementation notes)

Running log. Branch `feat/ws15-parser-fuzz` off `main` (`adadadc`). WS-15 = conformance / vector
/ fuzz completeness for the 1.0 bar. This PR ports the reference SDK's (mppx) **fuzz** layer for the
untrusted-input parsers, in the codebase's existing curated-deterministic-corpus idiom.

## Spec / parity target

mppx (`mppx@0.6.28`) ships three fuzz files, mined for this PR:

- `Challenge.fuzz.test.ts`
  - `deserialize` never throws an *unexpected* exception (TypeError/RangeError) on arbitrary input
    (`fc.string()`, 10k runs), i.e. only domain errors, never a crash.
  - 6 adversarial header categories: `Payment <arbitrary>`, unterminated quote `id="<s>`,
    escaped-char-at-boundary `id="\<s>"`, comma floods `,,,,`×n (n≤100), very long keys
    (1000–5000 lowercased chars), NUL/control bytes injected into `id="..."`.
  - serialize→deserialize round-trip over a valid-challenge arbitrary (id/realm/method/intent +
    request dict).
  - `deserializeList` round-trip over 1–3 challenges joined by `, `.
- `Credential.fuzz.test.ts`: Credential serialize→deserialize round-trip; Receipt round-trip.
- `tempo/session/Sse.fuzz.test.ts`: `parseEvent` never throws on arbitrary input (null or a valid
  message); valid-SSE-format round-trip; `iterateData` **chunk-boundary invariance** + never-throw on
  arbitrary chunked bytes.

## Fork decisions (asked the user, both confirmed)

1. **SSE chunk-boundary invariance → SKIP as N/A, documented.** mpp-swift has **no** SSE byte-stream
   chunk-reassembler: `URLSession`/`hummingbird` own wire framing, WS text frames and SSE blocks reach
   our code whole, and we only have block-level `SessionStreamEvent.parse(_ block:)` /
   `SessionWebSocketFrame.parse(_ json:)`. mppx's `iterateData` chunk-invariance test exercises mppx's
   *own* reassembler, which we deliberately don't have (no scope-creep into transport code just to
   create a fuzz target). We instead fuzz the block-level parsers for no-trap + round-trip. **No silent
   cap:** this is the documented reason the chunk-invariance category is not ported.
2. **Fuzz generation → curated deterministic corpus, matching the RLP idiom.** The codebase's existing
   adversarial pattern is `RLPTests` ("RLP encode/decode + adversarial inputs"): a hand-curated,
   deterministic corpus with exact typed-error assertions and explanatory comments, not random/
   property fuzzing. No `fast-check` dep; no seeded PRNG (would be a parallel primitive, G0 violation).
   The "10k random runs" robustness guarantee becomes "a curated corpus covering every adversarial
   category mppx fuzzes, each asserted to never trap and to round-trip idempotently when accepted."

## Swift-specific translation notes

- **Typed `throws(ParsingError)`** on `Challenge`/`Credential`/`Receipt` init makes mppx's
  "never throw an *unexpected* error" a compile-time guarantee. The runtime fuzz target is therefore
  purely **no trap** (force-unwrap, index OOB, integer overflow, precondition, JSON recursion blowup,
  quadratic time). Encoded as: parse each corpus input; reaching the assertion proves no-trap; on
  *accepted* inputs assert `headerValue` re-parses equal (idempotence) for a real invariant.
- **Stream codecs return `nil`** (non-throwing) → fuzz target is no-trap + nil-or-valid; on accepted
  inputs assert the parsed type matches the wire discriminator.
- **SSE folding**: `foldingLineTerminators` normalizes `\r\n`/`\r`→`\n`, so a `message` round-trip is
  byte-identical only for `\n`-only content. Round-trip equality cases use `\n`-only payloads; CR/CRLF
  folding is pinned by separate hand-built-block cases (a distinct behavior, not a restatement).

## Subtraction / dedup (G3.6)

Existing suites already assert basic parse/round-trip and missing/empty/invalid rejection
(`ChallengeTests`, `CredentialTests`, `ContentDigestTests`, `ExpiresTests`,
`SessionWebSocketFrameTests`, `ConformanceStreamCodecTests`) and the full verifier tamper/replay/
expiry/method matrix (`PaymentVerifierTests`). The fuzz suites add only **distinct** behaviors:
systematic adversarial no-trap corpus, idempotence on accepted inputs, and round-trip under
*stress* inputs (special chars, extremes, unicode), never a restatement of an existing exact
assertion.

## File layout

- `Tests/MPPCoreTests/ParserFuzzTests.swift`: Challenge + Credential + Receipt (mirrors mppx's
  Challenge.fuzz + Credential.fuzz, target-aligned to MPPCore).
- `Tests/MPPTempoServerTests/StreamCodecFuzzTests.swift`: SSE + WS-frame (mirrors mppx's Sse.fuzz).

## Resolved items

- **Foundation `JSONDecoder` deep-nesting → graceful throw, no trap.** Empirically probed (depth 100/
  500 decode; 1000/5000/10000 throw `DecodingError`): Foundation caps nesting at ~512 and *throws*
  beyond it. So the deeply-nested-JSON corpus case (Credential payload, WS frame) reaches `.invalidJSON`
  / `nil` and never stack-overflows; **no depth guard is needed at our layer**; the platform already
  fails closed. The corpus pins this (depth 2000).
- **Verifier tamper/replay/expiry/method audit → already complete, nothing to fill.** `PaymentVerifierTests`
  covers valid / mint-receipt / malformed / unsigned / wrong-secret / binding-mismatch (realm·intent·
  method) / expiry(past·future) / body-digest(match·mismatch) / replay / session-reuse-not-consumed /
  invalid-doesn't-consume / concurrent-single-win. The two remaining fail-closed settlement rejections
  (`.noSupportingMethod`, `.settlementUnverified`) are covered by the dedicated `PaymentMethodVerifyTests`
  plus `TempoProofIntegrationTests` and `MCPPaymentEndToEndTests`. Adding more would duplicate a home
  (G3.6). PR-1's net change is therefore exactly the two new fuzz files.

## Verification

- `swift build --build-tests` green (macOS).
- New fuzz suites: **14 tests / 5 suites pass** (ChallengeFuzz 36+36 args, CredentialFuzz 21,
  ReceiptFuzz 13, SSEFuzz 22, WSFuzz 20). Notably the multi-challenge list round-trip with quoted
  commas passes; quoting protects comma-splitting across `Payment` schemes.
- Affected targets `MPPCoreTests` + `MPPTempoServerTests`: **263 tests / 38 suites pass**, no breakage.
- Lint (CI parity): `swiftformat` clean; `swiftlint --strict` 0 violations (fixed: no-em-dash in two
  comments, `n`→`reps`, `lf`→`lfForm`, one trailing comma).
- Linux build/test: relies on CI matrix (the gate is macOS+Linux+Lint+Devin all green before merge).

## Review rounds (Devin)

All findings were Info-level (no bugs). Dispositions:

- **Round 1 (4):** (a) `CredentialFuzzTests` reached the all-optionals challenge by hard-coded
  `validCorpus()[3]` — *fixed*: now selected by property (digest+expires+opaque) via `#require`, so a
  reorder cannot silently weaken it. (b) SSE `neverTraps` round-trips only `.message` — intentional;
  JSON events covered by `jsonEventsRoundTrip`. (c) duplicate `controlChars` across two targets —
  acknowledged (a shared module for one constant is not worth it). (d) deep-nesting relies on
  Foundation's cap — acknowledged, safe either way and documented.
- **Round 2 (2):** (a) the control-char SSE block carries CR/LF, which SSE folding splits, so only
  0x00–0x09 survived the round-trip — *addressed*: added `controlCharsNoLineBreaks` (C0 range minus the
  LF/CR terminators) as a message round-trip case, so the full non-terminator control range now
  survives encode→parse. (b) `Int.min`/`Int.max` error statuses exceed JS `MAX_SAFE_INTEGER` —
  acknowledged with an in-code comment: these pin the Swift codec's full-range integer round-trip, not
  a cross-SDK claim (realistic small statuses are covered by `SessionWebSocketFrameTests`).

Every Devin thread was replied to and resolved (mpp-swift's merge gate requires all threads resolved).
