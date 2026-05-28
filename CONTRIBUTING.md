# Contributing to mpp-swift

Thanks for your interest. This project holds a strict quality bar: correctness against the MPP spec, cross-SDK interoperability, and idiomatic Swift. Speed is secondary to getting it right.

## Ground rules

1. **Spec is the source of truth.** Every behavior cites the exact normative section it implements, with a test asserting the spec's MUST/SHOULD directly. Where an interoperating peer diverges from the spec, that divergence is handled explicitly behind a compatibility switch (defaulting to spec-correct), never silently inherited.
2. **No flaky tests.** Inject the clock (no `Date()` in testable paths), stub the network in unit tests, seed randomness, never `sleep`, isolate state per test, assert byte-exact via canonical encoding. CI runs the suite repeatedly with randomized order; any nondeterminism fails the build.
3. **Test against the spec and the shared conformance vectors.** Each module asserts its normative requirements directly and runs the published MPP conformance vectors. Coverage must exceed a single happy path: round-trips, tamper, expiry, replay, wrong-method, and every documented compatibility mode.
4. **Idiomatic Swift.** Follow Apple's [API Design Guidelines](https://swift.org/documentation/api-design-guidelines/) and the conventions of the `swift-*` packages. Value semantics first; `Sendable` data; actors only for shared mutable state; typed `throws`; no force-unwraps; DocC on every public declaration.
5. **Tests land in the same commit as the behavior they cover.**

## Workflow

- Branch from `main`; open a PR; keep PRs scoped to one module or concern.
- `swift build` and `swift test` must pass on macOS and Linux before review.
- New public API requires a documentation comment and a SemVer note.

## License

By contributing, you agree your contributions are dual-licensed under Apache-2.0 OR MIT, matching the project.
