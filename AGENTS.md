# AGENTS.md

Guidance for AI agents and automated contributors working in this repository.

## What this is

`mpp-swift` is the canonical Swift SDK for the Machine Payments Protocol (MPP). Client and server are independent products built on a shared `MPPCore`. The package is built one module at a time under a strict quality bar.

## Non-negotiables

- **Spec first.** The MPP drafts at <https://paymentauth.org> are the source of truth. Cite the exact section you implement and test it directly. Do not silently match a reference SDK; reference SDKs (`mppx`, `mpp-rs`) deviate from the spec in known places — reconcile deliberately and record the verdict.
- **No flaky tests.** Deterministic clock, stubbed network in unit tests, seeded randomness, no `sleep`, per-test isolation, byte-exact assertions. CI runs a flaky-hunter.
- **Idiomatic Swift, not app conventions.** Follow Apple's API Design Guidelines and the `swift-*` package norms. This repository has no app-specific style file; do not import conventions from unrelated projects.
- **No hand-rolled cryptography.** Use vetted dependencies; pin and audit them.

## Reference implementations to compare against

- TypeScript: `wevm/mppx`
- Rust: `tempoxyz/mpp-rs`
- Same-domain Swift: `solana-foundation/mpp-sdk` (`swift/` directory)

Read their source (not just docs) when implementing a module, and port their test cases.

## Build & test

```
swift build
swift test
```

Both must pass on macOS and Linux. Integration tests against a Tempo localnet are gated behind `MPP_INTEGRATION=1`.
