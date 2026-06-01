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
- schema validates/【rejects】 credential payload -> covered by `buildCredentialSPT` (payload shape)
  + the server-side decode in PR-2.
- client produces valid credential string / includes externalId / token-provider forwarding /
  context override -> `buildCredentialSPT`, `buildCredentialExternalId`, `tokenRequestFacts`,
  `providerRefuses`, `wrongMethod`, `malformedRequest`.
- (server status mapping, Connect, replay, receipt -> PR-2; live + proxy -> PR-3.)

## Status
- **PR-1 (client) DONE locally:** `MPPStripe` target + product; `StripeMethod`, `StripeChargeRequest`,
  `StripeTokenProvider`, `StripeChargeMethod`; 16 tests. Full suite 704 green; swiftformat + swiftlint
  clean; no em dashes. Next: PR-2 server (verifier + Connect + concrete PaymentIntent client).
