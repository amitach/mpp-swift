# WS-14 CLI implementation notes

A running log of the WS-14 `mpp` CLI workstream and the vendor-neutral payment-approval seam it builds on. Updated as each PR lands.

## Scope and references
- Goal: a shipped `mpp` executable at client-CLI parity with the reference peer `mppx` (github.com/wevm/mppx), plus a `PaymentAuthorizer` seam (Touch ID for the GUI consumer, env/auto for headless and CI).
- Peers: `mppx` is the SOLE CLI peer; `mpp-rs` has no CLI. There is no normative CLI spec; the CLI is shaped by the protocol's client flow (draft-httpauth-payment-00) plus mppx behavioral/test parity (the G7.5 gate).
- The full G7.5 peer-test parity matrix is assembled in PR-H.

## PR-A: PaymentAuthorizer seam + approvalFacts + rail wiring (MPPClient, MPPMCP, MPPTempo, MPPStripe, MPPCore)

The consent seam consulted once per payment, before any credential is built. It unifies what were three independent per-rail gates into one path, and is the seam the GUI consumer (Touch ID) and the CLI (env/auto/TTY) both inject. PR-A is library-only and Linux-safe; the concrete TTY/biometric authorizers land in PR-B.

### G0 reuse (right primitives)
- Consulted at the single existing credential-build chokepoint: `PaymentClient.send` (just before `selection.method.buildCredential`) and `MCPPaymentClient.callTool` (the same call). One shared free function `authorizeSelection(method:challenge:with:)` lives next to the existing `selectPaymentMethod`, so the HTTP and MCP flows cannot drift.
- Reused `Challenge`/`Credential`/`Amount`/`Expires`/`MethodName`/`IntentName` and each rail's existing request decode (`TempoChargeRequest`, `SubscriptionRequest`, `StripeChargeRequest`) and approval fact set (`ChargeApproval`, `StripeTokenRequest`). No parallel transport, amount, or selection primitive was introduced.
- Added `Amount: Comparable` in MPPCore (the right home for a numeric type; reused by `SpendingCapAuthorizer` and, later, by a consumer's budget authorizer) rather than a private comparator. The comparison is exact at arbitrary precision (canonical base-units strings: longer is larger, equal length compares by digit order), so it is correct beyond any fixed-width integer.

### Verified at the source (the reason approvalFacts exists)
- `amount`, `currency`, and `recipient` are NOT top-level on `Challenge`; they live inside the method-specific base64url `request` blob, which only the rail can decode. So the central chokepoint cannot build a full approval request generically.
- Fix: `PaymentMethodClient` gains `approvalFacts(for:)` with a protocol-extension default that returns only the rail-agnostic fields (`PaymentApprovalRequest(generic:)`); each rail overrides it to fill amount/currency/recipient from its own decode. `amount`/`currency`/`recipient` are therefore OPTIONAL on `PaymentApprovalRequest`, and `SpendingCapAuthorizer` FAILS CLOSED on a nil amount (`PaymentDenied.amountUnknown`) rather than treating an unknown spend as free.
- The override is a protocol requirement satisfied by an extension witness in the same module, so it dispatches correctly through `any PaymentMethodClient`.

### Streaming / channel granularity (matters for a consumer budget)
- `TempoChannelMethod.buildCredential` runs PER CHARGE, keying an open channel by `(payee, token, escrow)`; the first charge opens (deposit from `depositPolicy`, not the charge amount) and later charges voucher cumulatively. So `authorize()` fires per voucher with the per-tick amount. A consumer's budget authorizer accumulates per `(realm, recipient, currency, intent)` and stays silent within an approved deposit; escrow is not needed for budgeting. The minimal seam already supports this with no SDK change beyond `approvalFacts`.

### Receipt surfacing (for a consumer ledger)
- HTTP receipts surface via the existing `onEvent` sink (`ClientEvent.paymentResponse(receipt:)`), not the return tuple; MCP returns `PaidResult.receipt`. A consumer ledgers from those; no SDK change needed.

### Decisions / reasoned deviations (G3.5)
- One consent point, no double-prompt: the central authorizer is the sole consent gate. The CLI (PR-C) always constructs Tempo methods with `approval: .allowAll` and the Stripe token provider as a pure SPT mint, so exactly one authorization fires per payment. This is a construction-time invariant the CLI factory owns.
- `TempoApprovalPolicy` is KEPT, not deleted (subtraction note below): it is shipped public API on three methods and guards the resolved `chainId` bound into the EIP-712 signature, a fact the central request cannot express (chain resolution happens inside `buildCredential`). A library embedder may still want that chain-bound defense-in-depth. The CLI demotes it to `.allowAll`.
- The Stripe token provider stays a separate concern from consent: its job is to mint the SPT instrument. Collapsing it into consent would conflate "deny" with "no token available" and break the later exit-code parity (payment-rejected vs stripe-error).
- A thrown authorizer error propagates unwrapped (like a method error), consistent with the flow's existing contract; it is not relabeled into `PaymentClientError`.

### Subtraction audit (G3.6)
- `PaymentDenied` carries only the three cases PR-A uses (`amountUnknown`, `overCap`, `currencyMismatch`); cases for the TTY/biometric authorizers are added in PR-B when they have a caller.
- Considered deleting `TempoApprovalPolicy`; kept it (see above), demoted by the CLI.
- The `TempoChannelMethod.approvalFacts` override lives in `TempoChannelMethod+ApprovalFacts.swift` (an extension), not the main type body, so it does not push the file past the file-length / type-body-length limits, the same reason `channelVoucherPayload` is file-scope. The other three rails' overrides are inline (their files are well under the limits).

### Verified
- `swift build` + full `swift test` green (743 tests). New tests: the authorizer seam over the HTTP `PaymentClient` (approve proceeds, deny short-circuits before `buildCredential` with no retry, the selected challenge is gated exactly once, the default `approvalFacts` is rail-agnostic), `SpendingCapAuthorizer` (under/at/over cap, nil-amount fails closed, currency match/mismatch), `Amount` ordering across the 64-bit boundary, each rail's `approvalFacts` decode (proof, channel per-tick, subscription checksummed, stripe), and the MCP client deny path.
- Lint clean: `swiftformat --lint .` (0.61.1), `swiftlint --strict` repo-wide, the no-em-dash gate, and the secret scan.
- Linux-safe: PR-A links no Apple-only framework (LocalAuthentication / Security arrive in PR-B/PR-E, platform-guarded). The CI Linux job is the backstop.

## Consumer access patterns (validated against Kapsicum PRs #489 / #539 / #543)

Reviewed how the first consumer (Kapsicum) exposes and accesses capabilities, to confirm the seam + CLI serve those situations with no design or tech debt and nothing consumer-specific in this SDK. Findings: Kapsicum runs an XPC capability broker + a `kapsicum-mcp` helper (#489); it spawns agent CLIs as subprocesses pointed at the helper, scrubbing secrets from the child env; the approve/deny decision is made APP-SIDE (its `CapabilityGateway` + Touch ID), and anything it spawns runs HEADLESS and FAILS CLOSED, never prompting. Payment is not built there yet; the hook would sit app-side in `CapabilityGateway.invoke()` / `CapabilityBrokerRunAuthorizer`.

Conclusion: NO structural change. The seam is a vendor-neutral, INJECTED `PaymentAuthorizer`, which is exactly what serves all three access situations:
- In-process (the primary path for a GUI consumer): the consumer imports the libraries and injects its OWN authorizer (its app-side gateway / Touch ID decision; a composite of kill-switch / velocity / budget / step-up is just a `PaymentAuthorizer` it writes). Zero SDK change.
- Subprocess CLI ("a CLI invoked by the app"): `mpp pay <url> --approve auto --max-amount <budget>` is the headless, no-prompt, fail-closed, JSON-out, exit-coded mode the subprocess contract needs. The app pre-decides; the CLI enforces the cap.
- External MCP into the app: the app gates as a seller with `MCPPaymentServer`; as a buyer it pays an external MCP via in-process `MCPPaymentClient` + authorizer. We are not the payer in the seller case.

Because the app decides in-app and invokes headless, the CLI never needs an IPC "delegate approval back to the parent" channel - which avoids a whole class of future debt. PR-C refinements folded in from this (so they are not retrofitted): (1) a hard no-prompt guarantee - the `--approve` factory must never select tty/biometric in a non-interactive context (detect `isatty`; require explicit opt-in); `auto` is already pure no-I/O; (2) `--json` surfaces `status` (success/denied/failed) + the receipt reference (the charge id) + an error code, so a parent records the outcome; (3) evaluate an idempotency option for safe subprocess retries on settled rails (the protocol's single-use challenge already covers same-challenge replay). Deferred, non-speculative candidate: a generic `CompositeAuthorizer` in `MPPAuth` only when a consumer needs chaining - the seam already composes in a few lines, so it is not built preemptively (G3.6).

## PR-B: MPPAuth product (TTY + Biometric authorizers)

The concrete, I/O-bound authorizers, in a new `MPPAuth` product (deps `MPPClient` + `MPPCore` only) so a consumer that needs only the seam pulls neither a TTY nor LocalAuthentication.

- `TTYPaymentAuthorizer`: writes a one-line prompt to stderr (stdout stays clean for `--json` / piping) and reads a yes/no from stdin; only an explicit `y`/`yes` approves, everything else (including end-of-input) denies (`PaymentDenied.declined`). Both ends are injected closures, so it is testable without a real terminal and builds on every platform.
- `BiometricPaymentAuthorizer`: `#if canImport(LocalAuthentication)` (absent on Linux, so the product still builds there). Probes `canEvaluatePolicy` first and denies with `.unavailable` when neither biometrics nor a device passcode exists (fail closed, never assume approval); uses `.deviceOwnerAuthentication` (biometrics with the automatic passcode fallback); a user cancel / failed match denies with `.declined`. Mirrors Kapsicum's proven `LAContext.evaluatePolicy` + `withCheckedThrowingContinuation` pattern. `LAContext` is created fresh per call (so the struct stays `Sendable`); the type and the prompt reason are injectable for tests.
- `PaymentDenied` (in MPPClient) grew `.declined` and `.unavailable(String)`, now that PR-B has callers for them (G3.6: added with a caller, not preemptively).

Risk recorded (G3.5): Touch ID from a bare CLI binary (no app bundle / signing identity) is unreliable, so it is best-effort there and degrades to passcode then deny; the real biometric path is the in-process GUI consumer. `--approve auto` + env keys is the supported headless/CI mode.

Verified: `swift build` + the `MPPAuth` suites green (TTY y/yes/no/EOF; biometric unavailable/approve/declined via a stub `LAContext`); `swiftformat --lint` + `swiftlint --strict` clean; Linux-safe (biometric guarded out).

## Security review (authorization system, PR-A + PR-B)

Adversarial pass over the payment-authorization path. Asset = the user's money; the authorizer is the gate that prevents unauthorized or misrepresented spend. Threat actor includes a malicious 402 payment server (it controls the challenge fields) and a misconfigured / hostile caller.

- **[FIXED - terminal injection]** The `TTYPaymentAuthorizer` prompt interpolated the server-controlled `description` / `recipient` / `realm` / `currency` raw into the stderr line. A crafted `description` (ANSI escapes, `\r`, `\n`) could rewrite or spoof the confirmation line - show a tiny amount while a large one is charged - and trick the operator into approving. Fix: `displaySafe(_:maxLength:)` strips control / format characters (and bounds the free-form description length) at the display boundary; applied to the TTY prompt and, defense in depth, the biometric reason. The validated digits-only `Amount` is shown as-is. Regression test: a `description` carrying `ESC[2K\r...` is neutralized and the true amount still shows. Sanitizing at the terminal sink (not in `PaymentApprovalRequest`) keeps the data model lossless for a GUI consumer (SwiftUI does not interpret escapes). Follow-up hardening (Devin): `displaySafe` also strips Unicode bidirectional formatting (LRM/RLM, the embeddings/overrides, the isolates) explicitly by code point - a "Trojan Source" visual reorder of the payee/amount - rather than relying on `CharacterSet` category membership; all three server fields (description, payee, currency) are length-bounded (120) so a long value cannot flood/wrap the line; tested with a U+202E in both the description and recipient.
- **[FIXED - consistency, fail-closed either way]** `SpendingCapAuthorizer` compared the pinned currency case-sensitively while the `PaymentApprovalRequest.currency` doc tells consumers to normalize case - the one built-in ignoring its own contract. It over-denied (never over-approved), so safe, but it would spuriously reject `usd` vs `USD` (or a checksummed vs lowercase address). Now case-insensitive; a missing charge currency still fails closed. Tested.
- **[Confirmed safe - no bypass]** The authorizer is consulted before `buildCredential` on BOTH client paths (`PaymentClient.send`, `MCPPaymentClient.callTool`); a denial throws unwrapped and the credential is never built / no retry is sent (tested: build count 0, one request). The `advertise` preflight and the non-402 fast path build no credential, so they correctly do not invoke it.
- **[Confirmed safe - authorized amount == paid amount]** Both `approvalFacts` and `buildCredential` decode the SAME `selection.challenge` deterministically, so there is no time-of-check/time-of-use gap between what is authorized and what is paid. If the decode fails, it fails closed: `approvalFacts` returns a nil amount (`SpendingCapAuthorizer` denies `.amountUnknown`) and/or `buildCredential` throws - no path authorizes a small amount and pays a large one.
- **[Confirmed safe - fail closed throughout]** `SpendingCapAuthorizer`: nil amount denies; currency mismatch (including a nil charge currency against a pinned cap) denies; the `Amount` comparison is exact at arbitrary precision (canonical digits-only form, no overflow). Every uncertain case denies rather than approves.
- **[Confirmed safe - no secrets in the seam]** `PaymentApprovalRequest` carries no SPT, private key, or `sk` (only display/identity facts), so an authorizer - or a consumer's audit ledger or any log of the request - never sees payment secrets.
- **[Guidance, doc added]** One authorizer may be shared across concurrent payments, so `authorize` can be called concurrently. A STATEFUL consumer authorizer (a running budget) must make its check-and-commit atomic or two in-flight payments can both pass before either is recorded (a TOCTOU overspend). Documented on the `PaymentAuthorizer` protocol; the built-in authorizers are stateless and safe.
- **[Consumer footgun, documented]** The authorizer sees the per-charge `amount`, NOT the channel-open DEPOSIT (set by the consumer's injected `depositPolicy`). A cap could approve a small per-tick charge while a larger deposit is locked. The deposit is consumer-controlled (not attacker-controlled), so this is not an external exploit, but a budget-aware consumer (Kapsicum) must also bound the deposit in `depositPolicy`, not only the per-charge cap.
- **[Property, not a vuln]** The central authorizer is a CLIENT-level gate; calling a method's `buildCredential` directly bypasses it. Mitigated by the per-rail policy (`TempoApprovalPolicy` / the Stripe token provider) the method still runs, and by documenting that consent lives at the client seam. Consumers should pay through `PaymentClient` / `MCPPaymentClient`.
- **[PR-C requirement from this review]** Headless `--approve auto` with `AllowAllAuthorizer` and a present key approves whatever the server demands. PR-C must require an explicit `--max-amount` (or an explicit unbounded opt-in) in non-interactive mode, and must never auto-select `tty` / `biometric` when not attached to a TTY (the no-prompt guarantee), so an unattended run cannot silently approve an unbounded spend.
- **[Pre-existing, restated]** `ClientEvent.credentialCreated` carries the built `Credential` (secret proof material); its doc already warns consumers not to log or persist it. Unchanged by this work; the warning stands for the consumer's `onEvent` sink.
