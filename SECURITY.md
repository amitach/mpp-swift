# Security Policy

`mpp-swift` handles payment credentials and signing keys, so security is a primary design constraint, not an afterthought.

## Reporting a vulnerability

Please report security issues privately via GitHub's "Report a vulnerability" (Security Advisories) on this repository rather than opening a public issue. You will get an acknowledgement within a few days.

## Security model

The SDK enforces the security considerations of `draft-httpauth-payment-00 §11` and the per-method drafts. Each requirement maps to a type, a default, a runtime guard, or a CI gate, not a doc comment alone:

- **Transport (§11.2):** TLS is required; non-`https` is rejected at runtime (minimum TLS 1.2, default 1.3). A scoped `allowInsecureLocal` opt-in permits loopback only, for tests and the conformance harness.
- **Credentials (§11.2.1):** credentials are redacted in `description`/`debugDescription`, excluded from errors, and held only for the duration of one request. Swift value-type copies make hard memory zeroization impossible, so the SDK promises redaction and minimal lifetime, and zeroizes only raw key buffers it fully controls.
- **Secret management (§11.2.2):** the server `MPP_SECRET_KEY` lives only in server-side stores (file / environment / KMS), never in a client Keychain, and supports rotation with historical-key verification.
- **Replay (§11.3) and idempotency (§11.4):** single-use proof semantics via an atomic replay store, consumed before any side effect; unpaid requests perform no work.
- **Amount verification (§11.6):** amounts are integer base units carried as a canonical string; a spending-approval policy runs before any signing; the human-readable `description` is never used for verification.
- **Caching (§11.10) and DoS (§11.12):** `Cache-Control: no-store` on 402 and `private` on receipted 200; a rate-limiter seam for challenge issuance and verification.

Credentials, receipts, and secret keys must never appear in logs, error messages, traces, or analytics. A CI gate scans for this.

## Cryptographic dependencies

EVM signing depends on vetted libraries (`swift-secp256k1` for ECDSA, `CryptoSwift` for Keccak-256, and a fixed-width integer package where needed) and, for Tempo transaction construction, an FFI binding to Tempo's own primitives. All crypto dependencies are version-pinned (exact) and audited; hand-rolled cryptography is avoided.

## Supported versions

Pre-1.0: only the latest release receives security fixes.
