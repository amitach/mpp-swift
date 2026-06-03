# Request-path lazy subscription renewal (implementation notes)

Running log. Branch `feat/ws-subscription-lazy-renew` off `main`. Implements the reviewed plan
(`~/.claude/plans/mpp-swift-lazy-renewal-plan.{md,html}`): mppx-faithful "optional lazy renewal" so a
returning subscriber, identified without an MPP credential, is authorized and charged inline if a
period is due.

## Scope (Tempo-only)

Subscriptions are a Tempo-rail feature: Tempo gives only a delegated key-authorization primitive, so
the SDK is the billing brain (`SubscriptionEngine` + `SubscriptionStore` + `TempoSubscriptionRenewer`).
Stripe ships native subscriptions and is one-off-charge-only here, so none of this touches Stripe.

## Design (peer-faithful Approach A)

mppx's `authorize` is a generic, per-method server hook run on credential-less requests, returning a
receipt + optional response (no credential). Faithful translation that preserves our `internal`-init
`MPPVerified` unforgeability invariant across modules:

- New seam in MPPServer: `RequestAuthorizer` + `AuthorizeOutcome` (`.authorized(Receipt?)` /
  `.respond(HTTPResponse, Data)`).
- `MPPVerified.credential` -> optional (`nil` on the authorize path). The authorizer returns a
  receipt; the MIDDLEWARE (only minter of `MPPVerified`) lifts it into
  `MPPVerified(credential: nil, receipt:)` and runs the existing proceed path (cache floor + receipt).
- Tempo `SubscriptionAuthorizer`: `resolveLookupKey(request)` -> `store.activeSubscription` ->
  `engine.renew`, mapping renewed/upToDate -> `.authorized`, inFlight -> 409, charge-throw -> 503,
  inactive/none -> nil (fall through to 402).

## Decisions / refinements as I go

- **Failure split (risk #4):** the engine's `renew` already returns `.inactive` for
  canceled/revoked/expired/superseded (its `isActive(at:)` checks expiry), so those fall through to
  402 (re-subscribe) for free. Only a renewer *charge throw* (transient on-chain failure; the claim is
  released) maps to 503 Retry-After. Distinguishing a *terminal* charge failure (e.g. wallet empty)
  from a transient one needs a typed renewer error; deferred (documented), since today expiry is the
  main terminal case and it is already `.inactive`.
- **Multi-instance:** exactly-once holds per process via the store actor; for multi-instance, the
  consumer plugs a durable atomic `SubscriptionStore`. Documented at the authorizer + in the store doc.
- **Single optional authorizer** (not a list) until a second exists (subtraction).

## Progress

- [x] `MPPVerified.credential` -> optional + doc; SIX readers updated (grep found one the initial
      scope missed: `PaymentVerifierTests` reads it via a var named `token`, not `verified`).
- [x] `RequestAuthorizer.swift` (protocol + `AuthorizeOutcome`).
- [x] `MPPServerMiddleware`: `authorizer` param + authorize branch in `handle()` (body cap first;
      credential-less only; `.authorized` lifted into a credential-less `MPPVerified` via a shared
      `serve()` helper that also runs the verified path; `.respond` returned as-is; `nil` -> 402).
- [x] `SubscriptionEngine`: two read-through accessors (`activeSubscription(forLookupKey:)`,
      `record(_:)`) so the authorizer depends only on the engine facade.
- [x] `SubscriptionAuthorizer.swift` + receipt helper + 409/503 retry builder.
- [x] Tests: `RequestAuthorizerTests` (7, generic seam) + `SubscriptionAuthorizerTests` (7, every
      RenewalOutcome branch via a controllable renewer). Full matrix from the plan covered.
- [x] Build macOS green; `swiftlint --strict` 0; `swiftformat` clean (it converted a `!` force-unwrap
      to `#require`); em-dash clean. Affected targets MPPServerTests + MPPTempoServerTests: 219 tests /
      29 suites pass. Linux relies on the CI matrix.

## Verification notes

- Security invariant held: the authorizer returns only a receipt; `MPPServerMiddleware` (same module
  as `MPPVerified`, so it can call the internal init) mints the credential-less token. A middleware
  with no authorizer still answers 402 (tested: `noAuthorizerStill402`). The `internal` memberwise
  init is untouched.
- A present credential skips the authorizer entirely (tested), so activation is unchanged.
- Failure split: canceled/revoked/expired/superseded surface as `RenewalOutcome.inactive` (the engine
  checks `isActive(at:)`), which falls through to 402 (re-subscribe); only a transient charge throw is
  503. Finer typing of terminal charge failures is the documented follow-up.
