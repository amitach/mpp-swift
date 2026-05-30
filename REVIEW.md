# Reviewing mpp-swift

mpp-swift is the canonical Swift SDK for the Machine Payments Protocol (MPP), the
HTTP 402 "Payment" authentication scheme. This guide tells a reviewer (human or
automated, e.g. Devin) what the project is trying to achieve and how to verify a
change properly. Read it before reviewing a diff.

## What we are building

A spec-faithful, reference-conformant, minimal Swift implementation of MPP.
Servers issue `WWW-Authenticate: Payment` challenges; clients present
`Authorization: Payment` credentials; settlement proof travels in
`Payment-Receipt`. The SDK is split into focused modules: `MPPCore` (wire/data
types), `MPPBodyDigest` (RFC 9530), `MPPServer` (challenge mint + verify +
middleware), `MPPClient` (the 402 flow), plus rails and transports added per
workstream.

Two goals govern every change:

1. **Spec fidelity.** Behavior matches the normative specs, byte for byte where
   they are byte-exact.
2. **Interoperability.** The wire format interoperates with the official
   reference SDKs.

## Verify against the spec first

Correctness is grounded in the spec and the RFCs it builds on. Judge a change
against these (the codebase cites the spec/RFCs, never an SDK):

- **The "Payment" scheme:** `draft-httpauth-payment-00`, hosted at
  https://paymentauth.org/draft-httpauth-payment-00.html (IETF datatracker:
  https://datatracker.ietf.org/doc/draft-ryan-httpauth-payment/). Key parts:
  challenge / credential / receipt grammar (section 5.1), the challenge-id HMAC
  binding input (section 5.1.2.1.1), the content-digest check (section 5.1.3),
  the receipt (section 5.3), problem types (section 8.2), status-code table
  (section 4.2), caching (section 11.10), security (section 11).
- **RFC 9110:** HTTP authentication. A `WWW-Authenticate` value may carry more
  than one challenge, comma-separated on a single line, as well as on separate
  lines (section 11.6.1). The auth-param grammar (tokens and quoted strings).
- **RFC 9457:** `application/problem+json`, the 402 error body.
- **RFC 9530:** Content-Digest, the request-body digest.
- **RFC 8785:** JSON Canonicalization Scheme, the byte-exact request encoding.
- **RFC 3339:** timestamps (`expires`, receipt settlement time).

## Cross-check the reference SDKs

The official MPP SDKs are listed at https://mpp.dev/sdk. The TypeScript SDK
(mppx, https://github.com/wevm/mppx) is the reference implementation; the Rust SDK
(mpp-rs, https://github.com/tempoxyz/mpp-rs) is the other primary reference;
Python, Go, and Ruby SDKs are also official. A change should interoperate with
these.

When a reference SDK and the spec disagree, do not blindly pick either side.
First investigate **why** the SDK diverges: read that SDK's GitHub issues, commit
history, and PR / code comments for a documented reason (a deliberate fix, a
known spec ambiguity, an interop concession). A reasoned, intentional deviation
may be the correct behavior to match; an accidental or stale one is not. Absent a
good reason, the spec wins. Either way, the decision and the evidence behind it
(the issue or commit that justifies it) are recorded in the PR. The same applies
when two reference SDKs disagree with each other.

When reviewing, cross-check interop-critical surfaces against the reference SDKs:
header grammar and parameter ordering, the HMAC binding input, problem-type URIs,
status codes, default-port and origin handling, and any place this SDK is
intentionally stricter than the references (those are called out in the PR).

## What to scrutinize

- **Wire-format byte-exactness:** JCS, unpadded base64url, header formatting, the
  positional HMAC binding input. Assert canonical bytes, not field-by-field.
- **Security, fail-closed:** TLS (https only; loopback only under an explicit
  opt-in), challenge-id HMAC (constant-time), replay (consume exactly once),
  expiry, body-digest, and no secret (credential payload, key) reaching logs,
  events, or error bodies.
- **Swift 6 strict concurrency:** `Sendable` correctness, no data races, no force
  unwraps, typed `throws`.
- **Scope:** each PR states what it builds and what it defers to a later
  workstream. Do not flag a deliberately deferred item (named in the PR) as a
  gap; do flag anything in scope that is wrong, missing, or untested.

## Patterns that have bitten us (check these on stateful / settlement changes)

These are distilled from real findings that passed CI green before review caught
them. On any change touching channels, vouchers, settlement, or shared mutable
state, scrutinize each:

- **A valid signature is not a valid amount.** When a client-supplied value drives
  a settlement or payout, bound it by the server's recorded state, never trust it
  downward. A payer can validly self-sign a *lower* terminal voucher; settle the
  higher of the client's value and the stored highest, so a close can never
  underpay what the channel already drew.
- **Set the in-progress guard before the await, after verifying authorization.**
  Mark state "closing"/"in-flight" atomically *before* any `await` on an external
  side-effect (an on-chain settle, an RPC), so concurrent operations are rejected
  during the window. But verify the request's signature *first*, or a bogus request
  can freeze the channel.
- **Setting a flag is not the same as checking it.** A guard that is set but not
  rejected-on-already-set lets two concurrent operations both proceed (e.g. two
  closes both broadcasting a settle = duplicate on-chain transaction). Single-flight
  means: throw if the flag is already set.
- **Gate inside the atomic transform, against fresh state.** A check computed
  against an earlier non-atomic read is a TOCTOU window. Move the gate (delta,
  monotonicity, balance) inside the serialized read-modify-write, and re-check
  *all* guarding invariants there (`closing`/`finalized`), not just the field being
  mutated, so a racing operation cannot leak a side effect.
- **Fail closed on parse/validation failure.** An unparseable amount or quantity
  must reject the request, never default to zero or a permissive value (a silent
  free request). Audit every `?? .zero` / `try?` on a value that gates money.
- **Field *types* are part of wire parity.** string vs number, `i64` vs `u64` are
  interop-breaking. Verify against the reference SDK's actual serialization *at
  source* (the struct field types), not by assumption: a strict peer rejects a
  type mismatch, and a lenient decoder silently drops the field. Preserve the
  distinction through decode (a quoted `"5"` stays a string; a bare `5` an integer).
- **Do not auto-rollback a guard after a side-effect that may have partially
  succeeded.** A settle broadcast whose response was lost may have landed on-chain;
  rolling the flag back and retrying risks a double settlement. Park deliberately,
  document why, and make real recovery read back the external state before retrying.
- **Forward/peer-compat capture must be type-preserving and byte-stable.** Unknown
  fields captured for compatibility must round-trip their type, and a value with no
  extras must encode byte-identically to before the change.

## The Rust FFI (`rust/tempo-tx-ffi`)

The `0x76` transaction builder is the one non-Swift, shipped build input (see
`ARCHITECTURE.md`). On a change here, scrutinize:

- **No hand-rolled transaction encoding.** The format must come from
  `tempo-primitives`, not from bytes we assemble ourselves. The `0x76` envelope and
  RLP/ABI come from the bound crate.
- **Pin + lockfile.** `tempo-primitives` stays on an exact git tag with a committed
  `Cargo.lock`; a version bump is reviewed as a security-relevant diff, and the
  byte-golden test must be regenerated deliberately (never silently) if it changes.
- **The golden vector is the regression net.** Any change to the produced bytes
  must be explained; the live-Moderato test is the authoritative on-chain check.
- **Pure Rust.** `default-features = false` must hold (no `std` → no `c-kzg`/`blst`
  C deps), so cross-compilation stays clean; `cargo audit` must pass.
- **Key material.** Private keys are zeroized after use; nothing is logged.
- **Boundary minimality.** Keep the FFI surface to building/signing a transaction;
  everything reachable without building a transaction belongs in Swift.

## The bar a change has already passed

Every change runs a gate pipeline before it reaches review: right-primitive reuse,
build plus tests on macOS and Linux, spec-and-reference reconciliation, a
subtraction audit (no dead or premature API), and a multi-lens pre-PR review
(correctness, maintainability, security, adversarial, reference-test-parity,
conformance). Lint is `swiftlint --strict` plus `swiftformat --lint` plus a
repo-wide no-em-dash gate, at zero warnings. A thorough review looks for what
those passes might still have missed: hostile inputs, temporal sequences, parallel
code paths, and spec corners that no test yet guards.

## References

Spec and protocol:

- MPP "Payment" scheme: https://paymentauth.org/draft-httpauth-payment-00.html
- IETF datatracker: https://datatracker.ietf.org/doc/draft-ryan-httpauth-payment/
- Protocol home: https://mpp.dev

RFCs:

- RFC 9110 (HTTP semantics, authentication): https://www.rfc-editor.org/rfc/rfc9110
- RFC 9457 (problem+json): https://www.rfc-editor.org/rfc/rfc9457
- RFC 9530 (Content-Digest): https://www.rfc-editor.org/rfc/rfc9530
- RFC 8785 (JSON Canonicalization Scheme): https://www.rfc-editor.org/rfc/rfc8785
- RFC 3339 (date-time): https://www.rfc-editor.org/rfc/rfc3339

Official SDKs (cross-check interop; correctness is still cited to the spec):

- SDK index: https://mpp.dev/sdk
- TypeScript (reference implementation), mppx: https://github.com/wevm/mppx
- Rust, mpp-rs: https://github.com/tempoxyz/mpp-rs
