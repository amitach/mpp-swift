# WS-11 - MPP Stripe rail - implementation notes (running)

The Stripe rail is an MPP method (`stripe`/`charge`): the client presents a Stripe Shared Payment
Token (SPT) in the credential; the server settles by creating a Stripe PaymentIntent. Two products
(`MPPStripe` client + `MPPStripeServer` server), mirroring the Tempo split, so a paying agent does
not pull `MPPServer`+`swift-crypto`. Plan: `~/.claude/plans/nested-crafting-map.md`. Reference peer:
`mppx` `src/stripe` (the sole Stripe peer; `mpp-rs` has no Stripe rail).

## G0 reuse map (no parallel primitives)
- `PaymentMethodClient` (MPPClient), `Challenge`/`Credential`/`Amount`/`JSONValue`/`MethodName`/
  `IntentName.charge` (MPPCore), `PaymentRange` (MPPClient). Mirrors `TempoProofMethod` /
  `TempoChargeRequest` / `TempoMethod`.

## Decisions / reasoned deviations (G3.5)
- **Client decodes the POST-mint challenge shape, NOT the mint inputs.** `StripeChargeRequest` has
  `amount: Amount` already in base units (no top-level `decimals`), `currency`, optional
  `description`/`externalId`/`recipient`, and `methodDetails{networkId, paymentMethodTypes[>=1],
  metadata?}`. (The mppx `Methods.ts` `z.transform` folds `networkId`/`paymentMethodTypes` into
  `methodDetails` and drops top-level `decimals`/`networkId`; the client never sees `decimals`.)
- **Credential carries no `source`** - matches mppx (its Stripe client sets none; the server omits
  `mpp_client_id` when source is absent). Stripe identifies the payer by the SPT, not a wallet DID.
- **SPT-provider seam** (`StripeTokenProvider`): no Stripe.js in Swift, so the agent injects the SPT
  out of band (the mppx `createToken` analogue). The provider doubles as the pre-pay gate (refusing
  to mint rejects the charge), so there is no separate approval policy.
- **`externalId`** is a client-config field on `StripeChargeMethod` (the caller's order ref),
  echoed into the credential payload, matching mppx's client param (distinct from the challenge's
  server-side `externalId`).
- **`spt` is a payment-authorizing secret**: never logged; `StripeTokenProvider` documents it; the
  source never reads the payload back (only writes it).

## G3.6 subtraction
- No approval-policy type (the token provider is the gate).
- `StripeChargeRequest` does NOT decode the wire's server-side `externalId`: it has no client-side
  consumer (the credential's `externalId` is a separate, client-set value), so decoding it would be
  dead API. Removed after a PR-1 review flag.
- `paymentMethodTypes` is decoded and surfaced to the provider but is NOT sent to the PaymentIntent
  (server-side, PR-2); recorded so PR-2 does not add `payment_method_types`.

## Peer-test parity matrix (G7.5) - PR-1 (client) slice
mppx `Methods.test.ts` + `client/Charge.test.ts`:
- name/intent == stripe/charge -> `StripeMethodTests`-equivalent via `StripeMethod.name` + ranges test.
- schema validates valid request -> `decodesValid`, `optionalAbsent`.
- schema rejects invalid request -> `missingCurrency`, `missingMethodDetails`, `missingNetworkId`,
  `invalidAmount`, `emptyPaymentMethodTypes`, `notBase64URL`.
- schema validates/rejects credential payload -> covered by `buildCredentialSPT` (payload shape)
  + the server-side `missingSPT` decode in PR-2.
- client produces valid credential string / includes externalId / token-provider forwarding /
  context override -> `buildCredentialSPT`, `buildCredentialExternalId`, `tokenRequestFacts`,
  `providerRefuses`, `wrongMethod`, `malformedRequest`.
- (server status mapping, Connect, replay, receipt -> PR-2; live + proxy -> PR-3.)

## PR-2 (server) decisions / deviations
- **Idempotency key** (G3.5 reasoned deviation): `mpp-swift_{challengeID}_{sha256hex(spt)}`. The spec
  mandates no format; the SPT is a payment-authorizing secret and the key rides a header
  intermediaries may log, so we hash it rather than inline it (the reference SDK uses the raw SPT).
  This is intentionally NOT cross-SDK-idempotent with the reference server for the same SPT;
  acceptable because a deployment runs one SDK and the MPP replay store already dedupes the
  challenge before any PaymentIntent (this key is defense-in-depth at Stripe).
- **Expiry + replay** are enforced by `PaymentVerifier` before `verify` runs (consume-before-verify
  at `PaymentVerifier.swift:90`, expiry at `:127`), so the verifier re-checks neither; Stripe's
  `idempotent-replayed` is mapped as defense-in-depth (`.alreadyProcessed`).
- **PI body sends `automatic_payment_methods` only**, never `payment_method_types` (tested absent).
  Form body is ordered (reference-SDK field order, metadata keys sorted for determinism) and WHATWG
  `application/x-www-form-urlencoded`-encoded.
- **Metadata** = `mpp_*` analytics first, user `methodDetails.metadata` merged over (user wins);
  `mpp_server_id == realm`; `mpp_client_id` only when a credential `source` is present (none here).
- **Connect** = full parity, validated before any Stripe call. `transferData.destination` is a
  required `String` on the Swift type, so the reference SDK's "missing destination" runtime case is
  unrepresentable (compile-time guarantee); the empty-destination case covers the non-empty rule.
- **Secret hygiene**: the `sk` rides only the `Authorization` header; never in errors (only Stripe's
  `error.message`), the path, or logs. `StripePaymentIntentClient` is not `Equatable`/`Hashable`.

## Peer-test parity matrix (G7.5) - PR-2 (server) slice
mppx `server/Charge.test.ts`:
- verifies via create / succeeded -> `succeeded`; receipt reference -> `succeeded` (reference == pi.id).
- metadata inclusion + analytics -> `metadata` (+ user-override).
- Connect apply (client + secretKey) -> `connectApply` + `StripePaymentIntentClientTests.formBody/headers`.
- 6 Connect validation rejections -> `connectRejections` (empty stripeAccount / empty onBehalfOf /
  fee negative / fee exceeds / empty transfer destination / transfer amount exceeds; + negative
  transfer amount). "missing transfer destination" -> N/A (type-enforced, see deviation).
- PI-creation failure -> `creationFails` + client `stripeError`.
- requires_action reject -> `requiresAction`; replay reject -> `replayed`; non-succeeded -> `unexpectedStatus`.
- idempotency-key format -> `idempotencyKey`.
- (live happy/invalid-SPT/expired/malformed + proxy -> PR-3.)

## PR-3 (conformance) decisions
- **No account-free cross-SDK harness for Stripe.** Unlike the proof (offline ecrecover) and
  subscription-activation (offline signature) rails, the reference `mppx` Stripe *server* verifies by
  creating a real PaymentIntent, so it needs a Stripe key. There is no keyless `mppx` Stripe server to
  test against. So account-free conformance is a **pure-Swift hermetic end-to-end** (the real client
  method builds an SPT credential for a server-minted challenge; the real `PaymentVerifier` pipeline
  verifies it, settling via a stub PaymentIntent client) plus the decode/shape parity from PR-1/PR-2.
  A Node `mppx` cross-SDK Stripe harness is deferred (needs an mppx server with a preview key).
- **Live (preview + secret gated):** `StripeLiveConformanceTests` mints a test SPT via Stripe's
  test-helpers and settles a real test-mode PaymentIntent through the concrete client; gated on
  `MPP_STRIPE_LIVE_SK` and **SPT private-preview enrollment** (skips otherwise). `run-stripe-live.sh`
  + a non-required `Conformance (stripe-live)` CI job (gated on `secrets.STRIPE_TEST_SK`,
  `contents: read`). Not run in the default suite; not verified locally (needs preview enrollment).

## Peer-test parity matrix (G7.5) - PR-3 (conformance) slice
mppx `Charge.integration.test.ts`:
- live happy path -> `StripeLiveConformanceTests.settlesLive` (preview-gated).
- invalid SPT -> covered by the live error path (the client surfaces Stripe's `error.message`); unit:
  `StripePaymentIntentClientTests.stripeError`.
- expired challenge -> enforced by `PaymentVerifier` (`:127`), not the method (framework-level).
- malformed payload (missing spt) -> `StripeChargeVerifierTests.missingSPT`.
- receipt-format stability -> `endToEnd` + `succeeded`.
mppx `proxy/services/stripe.test.ts` -> N/A here: an MPPProxy Stripe service (Basic-auth inject,
`Stripe-Account` strip) is a separate MPPProxy follow-up, noted as deferred.

## Live verification (post-merge follow-up)
First real run of `StripeLiveConformanceTests` against `api.stripe.com` (preview-enrolled key)
surfaced a genuine gap the hermetic tests could not: the SPT minted fine, but the PaymentIntent was
rejected because **we did not forward the charge `description` to the PaymentIntent**. The challenge
carries `description` and some accounts require it, so it is now plumbed through:
`StripePaymentIntentRequest.description` -> `StripeChargeVerifier` (from `request.description`) ->
`StripePaymentIntentClient` body. Unit-tested (verifier forwarding + the form body). The reference
SDK does not forward it either; this is a correct, reasoned addition (evidence: the live Stripe
error), not a parity break (Stripe is field-order-insensitive; the field is legitimate).

After that fix the live run advanced to the NEXT error on the test account: "export transactions
require a customer name and address." That account is an **Indian export account**, whose
regulatory requirements (customer identity) are outside the MPP SPT-charge data model (the challenge
has no customer field; mppx hits the same wall). Decision (with user): the SPT agentic flow targets
US / non-export accounts, so live verification uses a US/non-export test key; we do NOT add
India-export customer/shipping plumbing to the rail. The live job's key must therefore be a
non-export account.

## Spec reconcile vs draft-stripe-charge-00 (updated; compared after the live run)
Compared the implementation against `paymentauth.org/draft-stripe-charge-00`. The whole flow matches
(method/intent, request + credential fields, verify ordering, challenge binding, PI params, status
mapping, Connect + client-trust-boundary, receipt, no-receipt-on-error, TLS). Reconciled / noted:
- **`challenge_id` metadata key (§9): FIXED here.** The spec mandates `metadata: { challenge_id:
  challenge.id, ... }`; we emitted only `mpp_challenge_id` (reference-SDK analytics). Added the
  spec-required `challenge_id` key (kept the `mpp_*` namespace alongside). Unit-tested.
- **Idempotency key (§9, SHOULD):** spec shows `${challenge.id}_${spt}` (raw); we derive
  `mpp-swift_{id}_{sha256(spt)}` for header/log hygiene (the SPT is a secret). "Derived from the
  challenge ID and SPT" so arguably compliant, but diverges from the literal form (loses same-account
  cross-SDK idempotency with the reference server). PENDING user decision (keep hash vs match spec).
- **`request.externalId` (§6.1):** the spec lists it as a request (merchant) field; we don't decode
  it (no consumer; the receipt echoes the credential's externalId). Minor completeness gap, deferred.
- **`Stripe-Version` header:** spec is silent; required by the private-preview SPT field, so we add
  it. Not a gap.

## Status
- **PR-1 (client) MERGED (#103); PR-2 (server) MERGED (#104); PR-3 (conformance) MERGED (#105).**
  **WS-11 complete.** Follow-up: `description` forwarding (live-surfaced) + unit tests; live
  settlement verified on a US/non-export account. Deferred: a Node cross-SDK Stripe harness, an
  MPPProxy Stripe service, and (explicitly out of scope) India-export customer/shipping support.
