# WS-15 PR-3 MPPProxy cross-SDK conformance (implementation notes)

Running log. Branch `feat/ws15-proxy-conformance` off `main` (`adadadc`). WS-15 PR-3 adds the one
cross-SDK conformance surface the harness was missing: a foreign client paying a route THROUGH our
`MPPProxy` (the reverse direction, our proxy is the system under test).

## Direction fork (settled)

The plan noted a fork: our proxy fronting an mppx-gated origin, vs an mppx client through our proxy.
Only the second fits the proxy model. `MPPProxy` gates payment at ITS OWN boundary (mints a 402,
verifies, then forwards a scrubbed/bearer-injected request to a TRUSTED origin); it does not MPP-pay
upstream. So "fronting an mppx-gated origin" is N/A. The conformance is therefore reverse-style:
**mppx client -> our MPPProxy -> free origin** (user-confirmed).

## Host fork (settled): extend MPPConformanceServer

User chose to extend the existing `MPPConformanceServer` rather than add a new executable. The proxy
needs an origin to forward to; the conformance boundary is client<->proxy (the proxy->origin hop is
our own already-unit-tested `MPPHTTPTransport`/`URLSessionTransport` seam). Decision: a real loopback
origin, not an in-process stub, so the conformance exercises the proxy's real forward path end to
end (a conformance test should use the production transport, not a test double).

## What was added

- `Sources/MPPConformanceServer/ProxyConformanceRoutes.swift`:
  - `makeProxyConformance() -> MPPProxy`: one `ProxyService` ("echo") whose paid `GET /resource`
    route is gated by the SAME zero-amount Tempo charge gate the direct `/proof` route uses
    (`makeMiddleware`, reused, now internal), `basePath` "/proxy", default `URLSessionTransport`. Its
    origin baseURL is `http://127.0.0.1:<requestedPort>/origin`.
  - `registerProxyConformance(on:)`: mounts a free `GET /origin/resource` (returns
    `{"ok":true,"origin":"hit"}`) and the proxy responder on `GET /proxy/echo/resource` (GET only:
    the proxy declares a single GET route and self-routes, so a POST would 404 in the engine).
- `ConformanceServer.swift`: `main()` calls `registerProxyConformance(on: router)`. `requestedPort`,
  `makeMiddleware`, and `logIncoming` made internal so the new file reuses them. (`main()` kept under
  the 50-line `function_body_length` cap by extracting the helper.)
- `Package.swift`: `MPPProxy` + `MPPDiscovery` added to the `MPPConformanceServer` target deps.
- `Scripts/conformance/proxy-client.mjs`: the mppx client. `mppx.fetch` does the 402 -> sign Tempo
  proof -> retry dance; asserts a 2xx, the origin body relayed (`body.origin === "hit"`), and a
  `Payment-Receipt` header (the proxy attached it after a real verification).
- `Scripts/conformance/run-proxy.sh`: reverse-pattern harness (our server, mppx client), matching
  `run-reverse.sh`. Fixed PORT (default 8797): the proxy's origin URL is pinned to the server's port,
  so PORT=0 ephemeral is not supported for this route (documented in the script + code).
- `.github/workflows/ci.yml`: a `Cross-SDK proxy conformance` step in the `Conformance (local)` job,
  after the reverse step.

## Verification

- `run-proxy.sh` passes end to end (twice, on ports 8797 and 8796): mppx `GET /proxy/echo/resource`
  -> 402 (realm 127.0.0.1, tempo/charge, request amount 0 chainId 42431) -> Tempo proof -> 200 with
  `{"ok":true,"origin":"hit"}` and `Payment-Receipt` present. This proves the proxy mints the 402,
  verifies a FOREIGN credential, forwards over loopback to the origin, and relays the body + receipt.
- `swift build --target MPPConformanceServer` clean; `swiftlint --strict` 0 violations; repo-wide
  em-dash check clean. (The harness `.mjs`/`.sh` are not lint-gated in CI.)
- The transient "Address already in use" seen once was a lingering server from a prior local run, not
  a code issue; PORT override confirmed the script respects a fresh port.

## Notes / fork residue

- The proxy route is mounted only when PORT is fixed (`requestedPort != 0`); a PORT=0 ephemeral run
  (used only by the direct routes) skips it rather than mounting an unreachable `:0/origin`. The
  proxy gate shares the `/proof` gate's secret and binding but a separate replay store, which is
  harmless here: each gate is single-use within itself and no conformance run exercises cross-gate
  replay (real cross-route isolation is unit-tested by `MPPProxyTests.crossRouteReplayRejected`).
- Discovery surfaces (`/proxy/openapi.json`, `/proxy/llms.txt`) are reachable by the engine but not
  exercised by this conformance (the paid-route 402 flow is the cross-SDK boundary); a discovery
  conformance could be a later addition.
