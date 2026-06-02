# Subscriptions + metered streaming (WS-10 B6 + WS-9) - implementation notes

> **Status: COMPLETE, all merged to `main`.** PRs #84 (protocol core), #85 (store + renewal engine),
> #86 (SSE metered streaming), #88 (`.000Z` whole-second expiry interop fix), #89 (subscription
> cross-conformance, forward + reverse, live-verified vs mppx), #90 (WebSocket frames + SSE/WS codec
> conformance). Every Devin review thread resolved. Deferred follow-ups: a concrete on-chain
> `SubscriptionRenewer`, wiring activation into the `SubscriptionStore`, a live SSE/WS metering
> harness, and the real Stripe rail (WS-11).

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

### Peer validation against the chain's own codec (tempo-primitives 1.8.0)

To "be sure" without hand-chasing canonicality (and without runtime Rust), the pure-Swift RLP +
KeyAuthorization is differential-tested against `tempo-primitives` (the chain's own alloy-strict
codec) as a TEST ORACLE, in `rust/tempo-tx-ffi` (cargo, already in CI macOS+Linux):
- `key_authorization_encoding_matches_mpp_swift`: the chain's `KeyAuthorization` RLP is
  byte-identical to our Swift inner tuple (so keccak256 of it is the same sign payload).
- `chain_round_trips_mpp_swift_canonical_bytes`: the chain's strict decoder accepts our canonical
  bytes and recovers the same fields.
- Both PASS => a 3-way agreement (MPP-swift == ox == chain) for the subscription key-auth.
- FINDING (G3.5): tempo-primitives 1.8.0 added `is_admin: bool` + `account: Option<Address>` to
  `KeyAuthorization` (admin-key replay protection), after `witness`. They are NOT `rlp(skip)`, but
  with `#[rlp(trailing(canonical))]` they (and a None `witness`) trailing-omit for the subscription
  shape, collapsing to the same 6-field tuple as ox. A non-subscription / admin key-auth WOULD
  differ; our encoder deliberately targets the subscription shape only. Also: ox omits a
  `period == 0` limit field while the chain's `TokenLimit.period` is non-optional, but subscriptions
  always have period > 0, so it never bites. Only the subscription shape is validated.
- Dev-dep `alloy-rlp = 0.3.15` added to `rust/tempo-tx-ffi` (test-only).

### Devin round on #82 (RLP decoder hardening, all fixed + cross-validated)

Devin flagged the pure-Swift decoder was too lenient (a malleability hole, since the serialized
key-auth is signed/compared): 🔴 a list child could overshoot the list payload bound; 🚩 accepted
non-canonical short-form (a byte < 0x80 wrapped in a prefix); 🚩 accepted long-form lengths <= 55;
📝 `uint64` truncated > 8-byte integers. All fixed in `RLP.swift` (strict-canonical decode +
child-within-parent-bound) + the `uint64` guard, with adversarial tests in `RLPTests`. The
cross-validation above confirms our strict decode matches the chain's.

## PR-2 spec (subscription protocol core) - branch feat/subscription-core (off main ab0947f, has #82+#83)

Exact `tempo/subscription` Method (from mppx Methods.ts:289), the build target:
- **Credential payload**: `{ type: "keyAuthorization", signature: <hex serialized RLP TempoKeyAuthorization> }`.
- **Wire request** (post-transform, what the 402 challenge carries; `decimals` is consumed client-side,
  `amount` is already base-units): `{ amount: <base-units string>, currency: <addr>, recipient: <addr>,
  periodCount: <uint64 string>, periodUnit: dev_second|day|week, subscriptionExpires: <ISO8601>,
  description?: string, externalId?: string, methodDetails?: { accessKey?: {accessKeyAddress, keyType:
  p256|secp256k1|webAuthn}, chainId?: number } }`.
- period units: dev_second=1, day=86400, week=604800 (period seconds = periodCount * unit, uint64-bounded).
- subscriptionExpires must be whole seconds; expiry (key-auth) = its unix-seconds; MUST be strictly later
  than the challenge expiry (a verify-side check).

PR-2 files (mirror TempoChargeRequest's `init(challenge:) throws(DecodingFailure)` via
`challenge.request.decodedData()` + a Codable wire struct):
1. `Sources/MPPTempo/SubscriptionRequest.swift` - decode the wire request; expose periodSeconds (uint64,
   overflow-checked), expiry unix-seconds (parse ISO via RFC3339DateTime), accessKey?, chainId?.
2. `Sources/MPPTempo/TempoSubscriptionMethod.swift` - `PaymentMethodClient`: resolve accessKey
   (context/params/request.methodDetails) + chainId; build TempoKeyAuthorization {address=accessKey,
   chainId, expiry, limits=[{token=currency, limit=amount, period=periodSeconds}], scopes=[{currency,
   transferWithMemo 0x95777d59, [recipient]}]}; sign (root Secp256k1Signer) -> signedSerialization ->
   payload {type:"keyAuthorization", signature: hexPrefixed}; source = did:pkh(payer, chainId).
3. `Sources/MPPTempoServer/TempoSubscriptionVerifier.swift` - `PaymentMethodServer`: decode
   SubscriptionRequest; **re-encode-and-compare** = rebuild the EXPECTED TempoKeyAuthorization from the
   request + accessKey, `serialize()` it, require the credential's inner-tuple bytes == expected (so we
   never trust client decode; non-canonical/mismatched rejects); recover the payer via
   `TempoKeyAuthorization.recover(serialized:)`; assert expiry > challenge expiry. reusesChallenge=FALSE
   (activation is one-shot; renewals are server-driven in PR-3, which self-guards per the P0-1 invariant).
   No store/renewal/side-effects in PR-2 (PR-3).
4. Tests: hermetic activation round-trip through PaymentClient (402 -> key-auth credential -> verified);
   field-mismatch rejections (currency/amount/period/expiry/scope/recipient/chainId); + cross-SDK
   conformance vs mppx subscription activation (both directions) - may ride PR-2.5 like MPPMCP did.

## PR-2 BUILT (branch feat/subscription-core, off ab0947f) - 3 files + tests, all green

- `SubscriptionRequest.swift` (commit 7db5d19) - decode the wire request; periodSeconds (uint64,
  overflow-checked), expirySeconds (whole-second ISO), accessKey?/chainId?. Plus the SHARED
  `keyAuthorization(accessKey:chainId:)` builder (one per-period limit on currency, one
  transferWithMemo 0x95777d59 scope to recipient): the single place client AND verifier derive the
  authorization from, so the signed bytes and the verify-side re-encode cannot drift. 6 decode tests.
- `TempoSubscriptionMethod.swift` (commit 97e73ff) - PaymentMethodClient mirroring TempoProofMethod:
  failable init derives the payer wallet from the signer; supports = tempo/subscription + decodable;
  buildCredential = decode -> resolve chainId (request ?? default) + accessKey (configured ??
  request, else `noAccessKey`) -> approval gate -> `request.keyAuthorization(...)` ->
  `signedSerialization(with: signer)` -> payload `{type:"keyAuthorization", signature: hexPrefixed}`,
  source = did:pkh(payer, chainId). 15 tests, BYTE-REAL: the signed serialization recovers the wallet
  and deserializes back to the request-reconstructed authorization (not merely well-formed).
- `TempoSubscriptionVerifier.swift` (commit 1e35f44) - PaymentMethodServer, RE-ENCODE-AND-COMPARE:
  rebuild EXPECTED auth from the verifier's own challenge request + `request.accessKey` (so the access
  key is the one the SERVER issued, never the client's choice; a challenge with no accessKey =>
  `noAccessKey`, cannot verify), `deserialize` the credential's serialized auth + `recover` the payer,
  require `decoded == expected` (strict-canonical RLP decode + unique canonical encoding => this IS
  byte-equality of the signed inner tuple), require expiry strictly after the challenge deadline
  (challenge.expires ?? now), pin recovered payer == did:pkh source wallet. reusesChallenge=false
  (one-shot activation). 11 tests: client round-trip + the full reject matrix. Payload preamble
  extracted to `presentedAuthorization` to stay under the cyclomatic-complexity cap (the proof
  verifier's `protocolCheck` lesson).

### Gates / deviations (PR-2)

- KEY DISTINCTION (got it right): the authorization's `.address` is the DELEGATE (access key); the
  PAYER is the root signer, recovered from the signature. The verifier checks BOTH - `decoded ==
  expected` pins the delegate/limits/scope, and `payer == source` pins the root - they are different
  addresses and both must hold.
- DEVIATION: the client approval gate reuses `ChargeApproval` (the existing pre-sign approval
  primitive), which surfaces amount/currency/recipient/chain/challenge but NOT the recurring
  period/expiry. Documented inline. Reused per subtract-before-add rather than inventing a parallel
  `SubscriptionApproval`; revisit only if a policy needs to bound the period.
- G3.5: code/tests cite the spec; peer reconciliation stays here in the devlog.
- swiftformat + swiftlint --strict whole-repo clean; no em dashes; full suite 612 green.

### Still open on PR-2

- Cross-SDK conformance vs mppx subscription activation (both directions) - rides PR-2.5 like MPPMCP
  did (the hermetic activation round-trip through PaymentClient is already covered in PR-2).

## PR-3 plan (SubscriptionStore + renewal engine) - peer-mined, primitive-mapped

Peer (mppx, mined): `subscription/Store.ts`, `subscription/Types.ts`, `server/Subscription.ts`,
`subscription/KeyAuthorization.ts`. Our primitive to MIRROR: `MPPTempoServer/ChannelStore.swift`
(actor + `update(_:_: transform)` atomic CAS, the monotonic-guard-inside-update pattern from
`SessionMethod.acceptVoucher`). Time = injected `@Sendable () -> Date` (the FileReplayStore pattern),
NOT a global clock. On-chain transfer stays behind a seam (the open-builder seam pattern) so PR-3 is
hermetic + RPC-free.

PEER MODEL (faithful, idiomatic-Swift port):
- `SubscriptionRecord` (Sendable, Hashable): economic params (amount, currency, recipient,
  periodSeconds, expirySeconds) + identity (subscriptionId, lookupKey, externalId?) +
  serialized keyAuthorization + payer{address,chainId} + charging state (billingAnchor,
  lastChargedPeriod, reference, timestamp) + in-flight claim (inFlightPeriod?, inFlightReference?,
  inFlightAttempt? token, inFlightStartedAt?) + terminal (canceledAt?, revokedAt?).
- Period index = stateless: `max(0, floor((now - billingAnchor) / periodSeconds))`, `.infinity`
  when `now >= expiry` (no more charges).
- isActive = `canceledAt==nil && revokedAt==nil && now < expiry`.
- lookupKey -> subscriptionId -> record double-indirection (clean supersession: a new sub for the
  same lookupKey cancels the old).

ENGINE (two-phase commit, the P0-2 atomic lesson):
1. START (atomic update): already charged (`lastChargedPeriod >= periodIndex`) -> `.charged`;
   in-flight and not stale (`now - inFlightStartedAt < renewalTimeout`) -> `.inFlight`; else stamp
   inFlightPeriod + a fresh attempt UUID-equivalent (no Math.random in scripts; use an injected
   `@Sendable () -> String` token provider, default secure-random, like saltProvider) +
   `inFlightReference = "renewal:{subscriptionId}:{periodIndex}"` (stable idempotency key persisted
   BEFORE the side effect) -> `.started`.
2. SIDE EFFECT: call the injected `SubscriptionRenewer` seam with (record, inFlightReference) ->
   it builds + submits the recurring transferWithMemo using the stored keyAuthorization; returns a
   reference (tx hash). Re-check active before AND after (supersession/cancel races).
3. COMMIT (atomic update): verify inFlightPeriod + attempt still match (stale attempts can't
   overwrite a newer one), set `lastChargedPeriod = periodIndex`, clear in-flight, preserve terminal
   states set during the callback -> `.renewed(result)`.
- Timeout recovery: a stuck in-flight older than `renewalTimeout` (default 900s) can be taken over.

PR-3 files (planned): `SubscriptionStore.swift` (protocol + InMemory actor, mirror ChannelStore),
`SubscriptionRecord.swift` (model + period/isActive pure helpers), `SubscriptionEngine.swift`
(the two-phase renew + the `SubscriptionRenewer` seam protocol), tests (hermetic: period math,
already-charged/in-flight/renewed, concurrent renewals -> exactly one charges, timeout takeover,
supersession, cancel/revoke during in-flight). The live transferWithMemo submission via the FFI 0x76
builder either rides PR-3's seam impl or a follow-up; the hermetic engine is the PR-3 bar.

## Deviations / open

- The tuple builder targets the subscription shape (always emits expiry+limits+calls). A fully
  general KeyAuthorization (ox omits expiry/limits/calls conditionally when absent) is not needed
  yet; documented in the type doc. Revisit only if a non-subscription key-auth consumer appears.

## WS-9: the standalone live WebSocket transport (PRs #114, #115, #116)

The metered-session METERING CORE and WIRE CODECS shipped earlier (#86 SSE, #90 the WS
`{mpp:...}` `SessionWebSocketFrame` codec + offline cross-SDK codec parity vs mppx
`session/Sse.js` + `session/Ws.js`, all in `MPPTempoServer`). WS-9 proper is the LIVE socket
transport that drives that core over a real WebSocket.

**Architecture (two layers, decoupled):**
- `MPPWebSocket` (no external deps) - the transport-agnostic orchestration. `SessionWebSocketServer`
  (an actor that serializes every socket write; bridges an `AsyncStream<String>` inbound + a
  `SessionSocketWriter`) and `SessionWebSocketClient` (consumes the stream, auto-answers
  `payment-need-voucher` with a fresh voucher, returns the terminal receipt). Frame mapping matched
  to the reference `session/Ws`: auth/voucher receipt -> `payment-receipt`, chunk -> `message`,
  shortfall -> `payment-need-voucher`, stream-end / client close-request -> `payment-close-ready`,
  reject -> `payment-error` + close 1008.
- `MPPWebSocketLive` - the live adapters, written against the framework-agnostic `swift-websocket`
  primitives (`WSCore` inbound/outbound, `WSClient`), so the server binding works with any host
  exposing a WSCore upgrade; Hummingbird appears only in the test (to boot `app.test(.live)`).

**Conformance reconciliation (the key decision).** Three distinct things, proven three ways:
1. **Wire-format parity vs mppx** - PROVEN OFFLINE and required (`ConformanceStreamCodecTests`, #90):
   `SessionWebSocketFrame` round-trips the exact `{mpp:...}` forms mppx `session/Ws.js` emits/parses.
2. **Live transport over a real socket (both directions)** - PROVEN by the hermetic self round-trip
   (`MPPWebSocketLiveTests`, #116): a live Hummingbird WS server (our server adapter) <-> our client
   adapter over a real `ws://` socket, full metered session end to end. Gated behind `MPP_WS_LIVE`
   and run isolated on the Linux CI job + local macOS dev (see G3.5 below).
3. **Cross-SDK LIVE ws session vs mppx (our ws client <-> mppx ws server on a real socket)** - this
   rides the Tempo payment CHANNEL, whose open/voucher/close is settled ON-CHAIN (mppx's session
   server relays the open tx and settles close on Moderato; there is no in-memory/hermetic mppx
   channel mode - verified in `session-server.mjs`). So it could only run TESTNET-gated, the same rail
   and faucet setup as the existing `run-session.sh`. It is NOT separately built (deliberate, see
   G3.6): a standalone testnet ws rig (an mppx `Ws.serve` server + our client opening an on-chain
   channel via the Rust FFI + faucet) would re-exercise a composition that is ALREADY proven - the
   frame format (1, codec parity), the live socket mechanics (2, the self round-trip), and the
   on-chain channel open/voucher/close that `run-session.sh` ALREADY proves cross-SDK against the
   same mppx session server (over the SSE/HTTP transport) - with only the socket framing swapped. The
   marginal coverage (the swapped framing) is the one part already covered by (1)+(2), so the rig
   would add a blind, flaky, non-required job for no new assurance. Documented as a transport-
   substituted variant of `run-session.sh`, to build only if a ws-specific channel regression appears.

### G7.5 peer-test parity matrix (mppx `session/Ws` -> mpp-swift)

| mppx ws surface | mpp-swift | parity | proven by |
|---|---|---|---|
| `{mpp:...}` frame format (authorization/message/need-voucher/receipt/close-request/close-ready/error) | `SessionWebSocketFrame` | exact | `ConformanceStreamCodecTests` (#90, offline, required) |
| server `serve()` loop (auth-frame verify, stream, need-voucher, close handshake, error) | `SessionWebSocketServer` | match | `SessionWebSocketServerTests` (in-process, required, 6 tests) |
| client consume loop (send auth, auto-voucher on shortfall, receipt, close) | `SessionWebSocketClient` | match | `SessionWebSocketClientTests` (in-process, required, 4 tests) |
| live socket round-trip (server + client) | `MPPWebSocketLive` adapters | match | `MPPWebSocketLiveTests` (#116, real socket; Linux CI + local) |
| cross-SDK live ws session (on-chain channel) | covered by composition | deferred-redundant | (1) codec parity + (2) self round-trip + `run-session.sh` (on-chain channel, cross-SDK, same mppx server); standalone ws rig deferred, see conformance note 3 / G3.6 |
| metering loop (pay-as-you-go, voucher top-up, receipt) | `SessionStream` | match | merged #86/#90 + the above |

### G3.5 reconciliation (deviations, with reasons)

1. **`MPPWebSocketLive` is written on `swift-websocket` (WSCore/WSClient), not Hummingbird** - keeps
   the adapter framework-agnostic; the server binding works with any WSCore upgrade. Hummingbird is a
   test-only dep (boots the live server).
2. **No explicit queued-message cap / 429** (the reference SDK has one) - the server read loop awaits
   each frame before reading the next, so the transport's own backpressure bounds in-flight work; the
   reference cap is an artifact of its single-threaded runtime. Documented on `serve()`.
3. **The live round-trip test runs on the LINUX CI job only** - the GitHub macOS runner cannot reliably
   bind a localhost WS listener via NIOTransportServices (`NWListener` refuses connections in that
   sandboxed runner; the test passes on Linux CI and in local macOS dev). The in-process suites cover
   the orchestration deterministically on both platforms as the required gate.
4. **No retry / `Task.sleep` in the live test** - a Devin flag (the repo's no-sleep / no-papering
   rules). The connect must succeed first try; the macOS-runner limitation is handled by (3), not by
   retrying.

### G3.6 subtraction

No new module for the metering/codec core (it lives in `MPPTempoServer`, not a separate `MPPStreaming`).
`MPPWebSocketLive` dropped its unused `MPPTempoServer` dependency (transitive via `MPPWebSocket`). The
unstructured pump task is deliberate (a structured child awaited by the scope would deadlock - the
pump's inbound only closes when the handler/scope returns). No retry/sleep. The standalone cross-SDK
testnet ws harness is deliberately NOT added: it would re-prove a composition (codec parity + live
transport + the on-chain channel rail already cross-SDK-proven by `run-session.sh`) with only the
socket framing swapped, so the marginal coverage does not justify a new blind/flaky non-required job;
documented as a transport-substituted variant to build only if a ws-specific channel regression appears.
