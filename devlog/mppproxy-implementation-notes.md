# MPPProxy — implementation notes (running log)

Branch: `feat/mppproxy` off `origin/main` @ 5d0de54 (includes #80 discovery generate/validate).
Peer: `mppx/proxy` (`Proxy`, `Service`, `custom`/`openai`/`anthropic`/`stripe`).
Specs cited (never the peer, in shipped code): the "Payment" HTTP auth scheme
`draft-httpauth-payment-00`, payment-discovery `draft-payment-discovery-00`.

## What MPPProxy is

A 402-protected reverse proxy: it sits in front of one or more upstream HTTP services and gates
their routes behind MPP payment. Unpaid request to a paid route -> mint a `402` challenge; a paid
request (valid `Authorization: Payment`) -> verify, forward to the origin, relay the response with
`Payment-Receipt`. It also publishes discovery (`/openapi.json`, `/llms.txt`). It is the HTTP
analogue of what `MCPPaymentServer.gated` does for MCP, and it reuses the exact same gate.

## Decisions (confirmed with user 2026-05-31)

1. **TWO products, both shipped in THIS PR (user confirmed "engine + HB binding, both this PR" +
   "go full hummingbird / latest hummingbird"):**
   - **`MPPProxy`** = the framework-neutral engine: `handle(_ request: HTTPRequest, body: Data,
     now: Date) async -> (HTTPResponse, Data)` over `apple/swift-http-types` (same currency types
     as `MPPServerMiddleware.handle` and `MPPHTTPTransport`). Self-dispatches over its route table,
     gates, scrubs, forwards, relays, and serves discovery. NO Hummingbird dependency; hermetically
     testable against an in-memory transport. Deps: MPPServer + MPPClient + MPPCore + MPPDiscovery.
   - **`MPPHummingbird`** = the thin binding: builds a Hummingbird `Application`/`Router` from the
     proxy config, mounts the engine as a CATCH-ALL responder, collects the request body into Data
     and streams the engine's `(HTTPResponse, Data)` back. This is the ONLY place swift-nio /
     Hummingbird enters the graph. Deps: MPPProxy + Hummingbird.
2. **Hummingbird = latest, pinned `from: "2.25.0"`** (user: "latest hummingbird"). Chosen over Vapor:
   HB 2.x is built natively on `swift-http-types` + Swift 6 structured concurrency, so the body
   bridge is minimal and strict-concurrency clean; Vapor carries its own NIOHTTP1 types + heavier
   graph. PLATFORM: HB 2.25 manifest floor is macOS 11/13 (compatible with our macOS 13), but its
   runtime APIs are `@available(macOS 14, iOS 17, ...)` via an availability macro -> mark only
   `MPPHummingbird`'s entry points `@available(macOS 14, iOS 17, *)`; do NOT bump the package
   platform (the engine + all other products stay macOS 13). swift-nio is ALREADY in our graph via
   the MCP SDK, so HB's transitive adds (service-lifecycle, async-algorithms) are compatible. HB
   tools-version 6.1 <= our 6.2 floor. OSV/dependency-audit will scan the new transitive deps.
3. **Route matching = minimal segment matcher (in the engine).** Literal segments + single-segment
   `{param}`/`:param` wildcards + trailing `/*` (one segment) / `/**` (rest-of-path) catch-all,
   spelled the way Hummingbird's router does so engine + binding agree. The engine OWNS routing
   (self-dispatch) because `/openapi.json` + `/llms.txt` are generated FROM the route table and each
   route carries its payment binding; the HB binding mounts the engine as a catch-all (routing lives
   in ONE place, testable without HB, reusable by a future Vapor binding).
4. **Discovery surfaces = `/openapi.json` (spec) AND `/llms.txt` (peer-parity).** User explicitly
   chose to also serve `/llms.txt`. `/openapi.json` reuses `DiscoveryGenerator.generate` (#80);
   `/llms.txt` is a human/agent index (cited as peer-parity, draft has no llms.txt surface).

## Architecture / reuse (G0 — right primitives, do NOT reinvent)

- **Gate** = `MPPServerMiddleware.handle(request, body, now) { handler }` — already does
  mint-or-402 / verify / `Cache-Control` floor / `Payment-Receipt` attach over HTTPRequest/Response.
  One middleware instance per paid route (exactly how a real server app wires routes). The proxy's
  forwarding closure is the `handler`.
- **Forward** = injected `MPPHTTPTransport.send(request, body)` (concrete `URLSessionTransport`).
  Zero new transport.
- **Discovery** = `DiscoveryGenerator.generate(info:routes:serviceInfo:)` from the route table.
- New product `MPPProxy` deps: `MPPServer` + `MPPClient` + `MPPCore` + `MPPDiscovery`. Zero Rust
  (auto-passes the FFI-isolation must-not-reach-Rust set).

## New code (the small surface that is genuinely new)

- `Sources/MPPProxy/MPPProxy.swift` — the `handle` entrypoint + dispatch.
- `Sources/MPPProxy/ProxyService.swift` — `ProxyService { id, baseURL, routes: [RoutePattern: Endpoint], rewriteRequest? }`;
  `Endpoint = .free | .paid(middleware:, discovery: PaymentInfo)`.
  DESIGN NOTE: a paid route carries its discovery `PaymentInfo` EXPLICITLY alongside the middleware,
  rather than reaching into the middleware's private binding/challengeRequest. Keeps the gate's
  internals private and the discovery contract declarative.
- `Sources/MPPProxy/RoutePattern.swift` — the segment matcher (literal / `{param}` / `/**`).
- `Sources/MPPProxy/ProxyHeaders.swift` — request `scrub` + response `scrubResponse`. SECURITY CORE,
  faithful port of the peer's set: request drops `authorization`, `cookie`, `content-length`,
  `accept-encoding`, hop-by-hop (`connection`/`keep-alive`/`transfer-encoding`/`upgrade`/
  `proxy-authenticate`/`proxy-authorization`/`te`/`trailer`), `x-forwarded-*`; response drops
  `set-cookie` (a paid proxy must never let an upstream set cookies under the proxy origin -> a
  compromised upstream's `Set-Cookie; Domain=.proxy` would become a session-fixation primitive),
  `content-encoding`, `content-length` (re-streaming). Cited to defensive-proxy reasoning, not peer.
- `Sources/MPPProxy/ProxyDiscovery.swift` — build `[DiscoveryRoute]` from the service tables ->
  `/openapi.json`; render `/llms.txt`.

## Open / start-of-work TODO (to resolve as I implement)

- Upstream auth injection hook shape: a `rewriteRequest: (HTTPRequest) -> HTTPRequest` closure on
  `ProxyService`, plus a `bearer:` / `headers:` convenience initializer (peer parity). Applied AFTER
  scrub, BEFORE forward, so injected upstream creds are never confused with the client's Payment.
- basePath stripping + `/{serviceId}/upstreamPath` parse (peer `Route.pathname`/`parse`).
- 404 (no service / no route), 405 fallback semantics (peer falls back to path-only match for
  management POSTs that carry a credential) — decide how much of that to port vs. defer; record here.

## Verification plan

- `swift build` + `swift test` (hermetic, in-memory transport stub) green on macOS + Linux.
- `swiftformat .` then `swiftformat --lint .` + `swiftlint --strict` WHOLE-repo (CI Lint runs both).
- No em dashes (CI-gated). No `Co-Authored-By` trailer.
- Cross-SDK conformance vs `mppx/proxy` (a Swift client paying our proxy, and/or our proxy fronting
  a stub upstream) — scope after the hermetic bar; may ride a PR-2 like MPPMCP did.

## Peer reconciliation (G3.5) + test-parity matrix (G7.5)

Mined `mppx/src/proxy/{Proxy,Service}.test.ts` (peer ships its tests). Header scrub sets are already
an EXACT match (verified against `internal/Headers.js`). Mapping every peer behavior to our plan:

PORT (covered by the engine + a Swift test):
- GET /openapi.json returns discovery JSON; respects basePath; GET /llms.txt linked to discovery.
- 404 unknown service / unmatched route / empty path.
- free passthrough (`endpoint===true` <-> our `.free`); joins upstream base path + request path.
- 402 when no credential; full 402 flow with a real client (our hermetic PaymentClient e2e).
- bearer / custom-header injection to upstream; auth injected on free passthrough too.
- strips incoming `authorization`; preserves safe headers; forwards request body; forwards query.
- paid routes emit server events (assert via the middleware `onEvent` sink).
- Service.from: id/baseUrl, bearer, headers (one + many), mutate, no-auth => no rewrite, `custom` alias.

PORT (covered BY DESIGN — add explicit tests to prove it):
- "auto-injects proxy route scope and blocks same-economics replay across routes": in our design each
  paid route owns its OWN `MPPServerMiddleware` with its OWN `RouteBinding`, so a credential minted
  for route A is structurally rejected on route B (verify pins binding). TEST: mint on A, replay on
  B => 402 binding-mismatch. ("manual scope overrides" is N/A as a mechanism — the per-route
  middleware's binding IS the explicit scope; the caller chooses it.)
- "attaches receipts to proxied ERROR responses": our middleware attaches `Payment-Receipt`
  regardless of the handler's status, so a 4xx/5xx upstream still carries the receipt. TEST it.
- replay rejection (same credential/voucher reused) — the verifier's replay store. TEST it.

DEFER (explicit scope decision, follow-up — recorded so it is not a silent gap):
- **Management-POST method fallback** (peer tests: "management POST falls back to paid route with
  different method", "...uses credential method binding to disambiguate same-path paid routes",
  "exact-match management POST does not forward upstream", "paid GET fallback does not forward POST
  upstream", "POST to unregistered method does not fall back to free GET route", "charges proxied
  content requests and keeps management POSTs off the upstream"). This whole cluster exists ONLY to
  serve mppx's SESSION/CHANNEL rail, where management actions (topUp/close) arrive as POSTs to a path
  registered under another method and are disambiguated by the credential's method+intent binding.
  MPPProxy v1 gates ordinary paid endpoints with straightforward (method, pattern) matching; the
  path-only fallback is unnecessary until a session method is proxied. DEFER to a follow-up (PR-2,
  alongside the channel-method proxy). v1 uses exact method+pattern match, first-match-wins.
- **Per-endpoint option overrides** (`getOptions`, "per-endpoint options override service bearer"):
  v1's upstream-auth rewrite is per-SERVICE (one `rewriteRequest`/`bearer`/`headers`). Per-route
  option overrides are a convenience; defer with the management-fallback follow-up.

## Status (2026-05-31)

DONE + verified (swift build + swift test green, swiftformat + swiftlint --strict whole-repo clean):
- **MPPProxy engine** (`Sources/MPPProxy/`): RoutePattern (literal/`{param}`/`*`/`**`), ProxyHeaders
  (scrub/scrubResponse, byte-for-byte the peer's sets), ProxyService (+ bearer/headers convenience
  inits), MPPProxy.handle (dispatch -> gate -> scrub -> forward -> relay -> receipt), ProxyDiscovery
  (/openapi.json via DiscoveryGenerator + /llms.txt). 28 tests (RoutePattern + 2 engine suites),
  covering the full peer PORT matrix incl. cross-route binding rejection + upstream-error relay.
- **MPPHummingbird binding** (`Sources/MPPHummingbird/`): HummingbirdBridge (Request.head + collected
  body -> engine -> Response), ProxyResponder (catch-all, self-routing), GatedResponder (single
  terminal gated route, reuses gate.handle). `MPPHummingbird.application(for:port:...)` factory.
  3 tests incl. a LIVE server (.live) proving the bridge end-to-end + a router-mounted gated route.
- Hummingbird 2.25.0 pinned (FLOOR range); macOS-14 availability gated on the binding only; package
  platform stays macOS 13; swift-nio confined to MPPHummingbird. Package.swift carries a scoped
  `// swiftlint:disable file_length` (manifest, not a source file; can't split, has no types).
- Verified all HB APIs against the resolved checkout source (not memory): Request.head/collectBody,
  Response/ResponseBody(byteBuffer:), HTTPResponder.respond, Application(responder:configuration:),
  BasicRequestContext, BindAddress.hostname, HummingbirdTesting .live/.router + execute/TestResponse.

DONE (sweep part 2 + deep cleanup, 2026-05-31):
- **MPPConformanceServer migrated onto MPPHummingbird.** Deleted ALL raw-socket plumbing
  (bindListener / readRequest / writeResponse / readMore / parseHead / Head / the accept loop /
  SIGPIPE / sockStreamType / the Glibc/Musl/Darwin imports). Now a Hummingbird `Router` + two
  `GatedResponder`s (proof + FFI-gated session), registered for GET and POST, with
  `Application(onServerRunning:)` printing the preserved `listening http://127.0.0.1:<port>/proof`
  line (the run scripts parse it; PORT=0 -> channel.localAddress.port). The verifier wiring
  (TempoProofVerifier / SessionMethod) is byte-identical to before. `@main` guards `#available
  macOS 14` (HB runtime). VERIFIED: `run-reverse.sh` boots it + the real mppx client GETs /proof ->
  402 -> pays -> 200 verified (live socket). FFI-gated build (`MPP_TEMPO_FFI=1`) compiles too.
- **MPPTempoServer: NO rewiring/cleanup needed.** It is the transport-agnostic payment-method-server
  layer (TempoProofVerifier / SessionMethod / ChannelStore / RPCChannelStateProvider, all
  PaymentMethodServer/store conformances) with ZERO HTTP/socket code; it plugs into the gate
  unchanged. Only the HTTP-binding layer (MPPConformanceServer) needed migration.
- **Docs updated:** README modules table (MPPProxy + MPPHummingbird = available; MPPWebSocket /
  MPPVapor = planned) + status line; ARCHITECTURE.md module-layering table (two new rows).
- **No traces of the old approach** remain (grep: the only "raw socket"/"hand-rolled" hits are the
  new file's "not a hand-rolled socket loop" note + unrelated crypto comments). CONFORMANCE.md's
  "dev-only HTTP listener" description stays accurate.
- **Verified:** full `swift test` = 558 tests / 69 suites GREEN; `swift build` clean; FFI-gated
  build clean; `dependency-audit.sh` OK on all 20 transitive deps (swift-nio/Hummingbird graph);
  swiftformat --lint + swiftlint --strict whole-repo CLEAN. Package.resolved is gitignored (not
  committed). CI: the `swift test` jobs (macOS + Linux) now build/test MPPProxy + MPPHummingbird
  automatically; the Conformance (local) job's run-reverse.sh is unchanged and green; no CI edits
  needed (a dedicated MPPProxy cross-SDK conformance job can ride a later PR like MPPMCP's PR-2 did).

## Deviations / surprises (append as they happen)

- Engine self-dispatches (vs. delegating to Hummingbird's trie router) so routing lives in one place
  the discovery doc is generated from; the HB binding mounts the engine as a catch-all. Recorded as a
  deliberate divergence from "use the framework router" — keeps the engine framework-neutral + the
  Vapor path open, at the cost of not using HB's optimized trie (fine for a modest proxy route table).
