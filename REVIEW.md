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

- **The "Payment" scheme:** `draft-httpauth-payment-00` (hosted at
  paymentauth.org; IETF datatracker `draft-ryan-httpauth-payment`). Key parts:
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

The official MPP SDKs are listed at https://mpp.dev/sdk. The TypeScript SDK is the
reference implementation; the Rust SDK is the other primary reference; Python, Go,
and Ruby SDKs are also official. A change should interoperate with these. When an
SDK and the spec disagree, the spec wins unless interoperability requires
otherwise, and the divergence is documented in the PR.

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

## The bar a change has already passed

Every change runs a gate pipeline before it reaches review: right-primitive reuse,
build plus tests on macOS and Linux, spec-and-reference reconciliation, a
subtraction audit (no dead or premature API), and a multi-lens pre-PR review
(correctness, maintainability, security, adversarial, reference-test-parity,
conformance). Lint is `swiftlint --strict` plus `swiftformat --lint` plus a
repo-wide no-em-dash gate, at zero warnings. A thorough review looks for what
those passes might still have missed: hostile inputs, temporal sequences, parallel
code paths, and spec corners that no test yet guards.
