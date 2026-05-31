# AGENTS.md

Guidance for AI agents and automated contributors working in this repository.

## What this is

`mpp-swift` is the canonical Swift SDK for the Machine Payments Protocol (MPP). Client and server are independent products built on a shared `MPPCore`. The package is built one module at a time under a strict quality bar.

## Non-negotiables

- **Spec first.** The MPP drafts at <https://paymentauth.org> are the source of truth. Cite the exact section you implement and test it directly. Where an interoperating peer diverges from the spec, reconcile deliberately and default to spec-correct behavior, exposing the divergence behind a compatibility switch rather than inheriting it silently.
- **No flaky tests.** Deterministic clock, stubbed network in unit tests, seeded randomness, no `sleep`, per-test isolation, byte-exact assertions. A flake surfaces on its own CI run; fix the root cause, never paper over it with a retry.
- **Idiomatic Swift, not app conventions.** Follow Apple's API Design Guidelines and the `swift-*` package norms. This repository has no app-specific style file; do not import conventions from unrelated projects.
- **No hand-rolled cryptography.** Use vetted dependencies; pin and audit them.

## Conformance

Test every module against the normative drafts and the published MPP conformance vectors. Coverage must exceed a single happy path: round-trips, tamper, expiry, replay, wrong-method, and every documented compatibility mode.

## Build & test

```
swift build
swift test
```

Both must pass on macOS and Linux. Integration tests against a Tempo localnet are gated behind `MPP_INTEGRATION=1`.
