# Security Policy

`mpp-swift` handles payment credentials, signing keys, and server secrets, so security is a primary design constraint, not an afterthought. This policy is enforced by types, defaults, runtime guards, and CI gates, never by a doc comment alone.

## Reporting a vulnerability

Report security issues **privately** via GitHub's "Report a vulnerability" (Security Advisories) on this repository, not a public issue or PR. You will get an acknowledgement within a few days. Please do not publicly disclose until a fix is released and consumers have had a reasonable window to update. Good-faith research is welcome; do not run tests against systems you do not own.

## Supported versions

Pre-1.0: only the latest release receives security fixes.

## Threat model

The SDK is built to be safe against:

- a **malicious counterparty** (a client forging or replaying a credential; a server over-charging or leaking a credential);
- a **network attacker** (MITM, downgrade, replay);
- a **supply-chain attacker** (a compromised dependency, build action, base image, or maintainer account); and
- an **untrusted signature or credential byte stream** reaching a verifier.

Assets protected: payment credentials, signing private keys, the server challenge secret, and the integrity of the shipped artifact.

## Protocol security controls (`draft-httpauth-payment-00 §11`)

Each requirement maps to a type, a default, a runtime guard, or a CI gate:

- **Transport (§11.2):** TLS required; non-`https` rejected at runtime (minimum TLS 1.2, default 1.3). A scoped `allowInsecureLocal` opt-in permits loopback only, for tests and the conformance harness; the test suite rejects a non-loopback server over plain HTTP.
- **Credentials (§11.2.1):** redacted in `description`/`debugDescription`, excluded from errors, held only for one request. Swift value-type copies make hard memory zeroization impossible, so the SDK promises redaction and minimal lifetime, and zeroizes only raw key buffers it fully controls.
- **Secret management (§11.2.2):** the server challenge secret lives only in server-side stores (file / environment / KMS), never in a client Keychain; rotation with historical-key verification; a minimum key length is validated on load.
- **Replay (§11.3) and idempotency (§11.4):** single-use proof semantics via an atomic replay store, consumed before any side effect; unpaid requests perform no work.
- **Amount verification (§11.6):** amounts are integer base units carried as a canonical string; a spending-approval policy runs before any signing; the human-readable `description` is never used for verification. `Double`/`Float` are banned from amount paths.
- **Caching (§11.10) and DoS (§11.12):** `Cache-Control: no-store` on 402 and `private` on a receipted 200; a request body cap (HTTP 413 over a fixed limit); a rate-limiter seam for challenge issuance and verification.

Credentials, receipts, and secret keys must never appear in logs, error messages, traces, or analytics.

## Cryptographic hardening

- **Audited libraries only; no hand-rolled cryptography** (an `AGENTS.md` non-negotiable). EVM curve operations use Bitcoin Core's `libsecp256k1` (via `swift-secp256k1`); standard NIST primitives (SHA-256, HMAC) use `swift-crypto` (BoringSSL-backed). Keccak-256 uses the vetted `CryptoSwift` because `swift-crypto` ships no Keccak.
- **secp256k1 signing:** deterministic **RFC 6979** nonces (no RNG-derived nonce, so no nonce-reuse or weak-RNG key extraction); the signing context is **randomized** (`secp256k1_context_randomize`) for side-channel blinding; the signer signs an already-computed 32-byte hash directly.
- **Signature malleability:** `libsecp256k1` emits canonical **low-`s`** signatures. Verification recovers the signer address and compares it to the expected address; an unrecoverable or malformed signature yields no match. The recover path is bounds-checked (65-byte `r||s||v`, `v` in `27...30`) and re-validated at the C boundary so a crafted signature cannot abort the process or read out of bounds. *(Inbound `s <= n/2` rejection per EIP-2 is a documented hardening item for any path that ever treats signature bytes as an identifier; today identity is by message content, not signature bytes.)*
- **Keccak-256, not NIST SHA3-256:** the EVM hash uses `pad10*1` with the `0x01` suffix; NIST SHA3 uses `0x06` and produces different digests. The wrapper is pinned by the canonical known-answer vector `keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`, guarding against a provider silently selecting the wrong variant.
- **EIP-712 typed data:** the `0x19 0x01` prefix is applied exactly; the domain separator binds **`chainId` and `verifyingContract`** (cross-chain and cross-contract replay defense); the `typeHash` prevents struct type-confusion. Every digest and signature is verified **byte-for-byte against an independent implementation** (viem) in the test suite.
- **Constant-time comparison** for any MAC, digest, or secret-equality check (never `==` or early-return).
- **Integer-only money:** amounts are smallest-unit integers carried as canonical decimal strings; floating point is banned from all amount, fee, and conversion paths.

## Supply-chain security

The shipped artifact is built only from this repository's source plus a small set of pinned SwiftPM dependencies. The controls below defend against compromised dependencies, build actions, base images, and maintainer accounts: the class behind the xz/`liblzma` backdoor (CVE-2024-3094), the npm "Shai-Hulud" self-replicating worm and the chalk/debug and axios npm compromises, the `tj-actions/changed-files` action compromise (CVE-2025-30066), and the March 2026 `aquasec/trivy` Docker image compromise.

### Dependency policy

- **Minimal dependencies.** Each is added only when no vetted in-ecosystem option exists.
- **Source-vetted before adding.** Before a dependency lands, its source is read for build/install scripts, transitive dependencies, and dangerous APIs, and the result is recorded.
- **Pinned, with a library-appropriate split.** The niche, security-critical crypto dependencies are pinned **exact** (low conflict risk). The widely-shared Apple packages use a **floor range** (`>=` a reviewed-safe version, `<` next major): exact-pinning them in a library would force unresolvable diamond conflicts on any consumer that also depends on them, while a floor still blocks a silent downgrade to an older vulnerable release, and the OSV gate (below) flags any advisory. Bumps are security-reviewed.
- **No arbitrary install/build scripts.** Unlike npm, SwiftPM does not execute dependency-defined install hooks; build plugins, if any, are reviewed during vetting.

Inventory:

| Dependency | Pin | Purpose | Notes |
|---|---|---|---|
| `apple/swift-crypto` | floor `3.15.1 ..< 4.0.0` | SHA-256, HMAC | BoringSSL-backed. The 4.x X-Wing HPKE advisory (CVE-2026-28815) does not affect the 3.x line |
| `apple/swift-http-types` | floor `from: 1.5.1` | HTTP currency types | no published advisories |
| `21-DOT-DEV/swift-secp256k1` | exact `0.21.1` | ECDSA over `libsecp256k1` | last release on swift-tools 6.0; vendors Bitcoin Core C |
| `krzyzanowskim/CryptoSwift` | exact `1.10.0` | Keccak-256 only | zero external package dependencies; used only for `SHA3(.keccak256)` |

`swift-asn1` (1.7.0) is a transitive dependency of `swift-crypto`; its DoS advisory CVE-2025-0343 is fixed in 1.3.1, below our resolved version.

### Integrity and pinning

Git tags are mutable: a maintainer, or an attacker with write access, can move a tag to a different commit (as in the `tj-actions` and `xz` cases). Our anchors against this are the version pins (exact, or a reviewed floor) in the manifest plus the resolved commit revision recorded at resolution time. Dependency bumps are reviewed as security-relevant diffs.

### Dependency monitoring

**A CI gate scans every pinned dependency against the OSV / GitHub Advisory Database on every push and PR** (`Scripts/dependency-audit.sh`, the `Dependency audit (OSV)` job): it resolves the graph and queries OSV.dev for each pin, failing the build if any version has a matching advisory. (`osv-scanner` has no `Package.resolved` extractor, and OSV's Swift records are inconsistent on package naming, so the script queries the OSV API directly for both the bare and full repository-name forms and unions the results.) Dependabot additionally proposes GitHub Actions bumps (kept on pinned SHAs); SwiftPM dependency bumps are reviewed manually against advisories, since the library does not commit `Package.resolved`.

### Rust FFI: the 0x76 transaction builder

The Tempo `0x76` channel transaction (open/topUp/close) is built by `rust/tempo-tx-ffi`, a Rust crate that binds Tempo's own `tempo-primitives` (the chain's canonical transaction format). Unlike the npm tooling below, **this is a build input that ships in the artifact**, so it is a higher-trust surface and carries its own controls:

- **Pinned to an exact git tag** (`tempo-primitives@1.8.0` on `tempoxyz/tempo`) with a **committed `Cargo.lock`**, so the entire transitive tree (the `alloy` / `revm` / `k256` crates, ~270 in total) is locked to specific revisions. Tag mutability is anchored the same way as the Swift deps: an exact pin plus the resolved revision in the lockfile. The source is public and **Apache-2.0**, so a snapshot can be vendored if upstream ever becomes unavailable.
- **Built in CI from pinned source, on macOS and Linux** (the `Rust FFI` job), not committed as an opaque prebuilt blob, so the binary is reproducible from the source any reviewer can read (provenance).
- **The published Apple artifact is checksum-pinned.** The release pipeline (`.github/workflows/release-ffi.yml`) builds the xcframework from pinned source and publishes it as a GitHub-release asset; `Package.swift` references it by `url` **and SHA-256 `checksum`**, so SwiftPM rejects a tampered or substituted download. Until a release is wired, the FFI builds from source behind `MPP_TEMPO_FFI` (no opaque binary is consumed). Linux always builds from source.
- **`cargo audit` (RustSec advisory DB) gates the Rust tree on every push**: the Rust analogue of the Swift OSV gate, closing the gap that OSV does not cover Cargo dependencies. It fails on a known vulnerability. (At adoption: 0 vulnerabilities across the tree; two benign unmaintained-crate warnings, `derivative` and `paste`, inherited from `alloy`/`revm`.)
- **Pure Rust** (`default-features = false`): the build pulls **no C dependencies** (`c-kzg`/`blst`/`ring`/`aws-lc` come only via the `std` feature, which is not enabled), shrinking the native attack surface and keeping cross-compilation clean.
- **Byte-exact golden test** locks the transaction output (deterministic RFC-6979 signing) and detects any change from a format update, a dependency bump, or our code; the live-Moderato test is the authoritative on-chain check. No transaction encoding is hand-rolled.
- **Key hygiene:** the 32-byte private key is zeroized immediately after the signing key is built (the `k256` signing key is itself zeroize-on-drop).

### Build-tooling isolation (test-vector generation)

Cryptographic test vectors are generated with npm packages (`viem`, `@noble/curves`, `js-sha3`). These are **never shipped and never a build input** to any Swift target; the only thing that crosses into the repository is **static, code-reviewed vector data** (hex / JSON), which is additionally **cross-checked against the SDK's own independent implementation**. Because the npm ecosystem is the most actively-attacked supply chain (self-replicating worms exfiltrating tokens via `pre`/`postinstall` hooks; maintainer-account takeovers shipping RATs), vector generation runs with `--ignore-scripts`, against pinned versions, in an environment holding no credentials. A compromise of those packages can therefore at worst corrupt a reviewed data file, never inject code into the shipped artifact.

### Cross-SDK conformance harness (CI)

The `Conformance (local)` CI job installs npm packages (`mppx`, `viem`, and their transitive dependencies) to run the reference TypeScript server the Swift client is tested against (`Scripts/conformance/`). Like vector generation, these packages are **dev-only**: never shipped, not part of the SwiftPM dependency graph (so out of the OSV gate's scope), and installed with `npm ci --ignore-scripts` against a **committed lockfile** (pinned, reproducible, no install hooks). The job is granted **no secrets** and only `contents: read`, and the `local` mode makes **no outbound network calls** (the zero-amount proof is verified by `ecrecover`), so a compromised npm dependency is contained: it cannot exfiltrate or reach the network. A separate **non-required** `Conformance (testnet)` job additionally probes the live Moderato node (`rpc.moderato.tempo.xyz`); it is the one job that opens outbound egress while third-party code runs, which is why it is kept out of branch protection, holds no secrets, and is disabled if it proves flaky.

### CI/CD hardening

- **Actions pinned to full commit SHAs**, not mutable tags (the `tj-actions/changed-files` compromise re-pointed version tags to a malicious commit; SHA-pinned references were unaffected). Dependabot bumps the SHAs.
- **Least-privilege token:** workflows default to `permissions: contents: read`; any extra scope is granted per job.
- **Base image pinned by digest** (`swift@sha256:...`), not the mutable `swift:6.0` tag (the `aquasec/trivy` Docker Hub compromise overwrote mutable tags, including `latest`). Dependabot does not manage workflow `container:` digests, so the base image is **rotated manually** on a roughly monthly cadence and whenever a Swift or Ubuntu base advisory lands (the OSV gate covers SwiftPM dependencies, not the OS image, so this cadence is the control for the base layer).
- **No secrets in untrusted contexts:** secrets are never exposed to fork-triggered runs; `pull_request_target` against fork code is avoided.
- **Source-scan gates:** CI fails on a literal U+2014 em dash anywhere tracked, on swiftlint/swiftformat violations, and on credential/secret patterns in source.
- **Branch protection:** required status checks and required conversation resolution on `main`. *(Targets: required signed commits and required review.)*

### Provenance (targets)

Build-provenance attestations and an SBOM per release are planned once SwiftPM's SBOM support stabilizes.

## Disclosure

Confirmed vulnerabilities are fixed in a new release, credited to the reporter unless they prefer otherwise, and published as a GitHub Security Advisory.
