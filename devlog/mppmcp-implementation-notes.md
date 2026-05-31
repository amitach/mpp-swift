# MPPMCP implementation notes

Running log for the MPPMCP workstream (the JSON-RPC / Model Context Protocol payment rail).
Spec: `paymentauth.org/draft-payment-transport-mcp-00`. Reference: mppx 0.6.28 `mcp-sdk/{client,server}`.
Plan: `~/.claude/plans/mpp-swift-mppmcp-plan.md` (per-developer, gitignored).

## Decisions and deviations (as they happen)

### The SDK fork (prerequisite, done)
The stock official MCP Swift SDK (`modelcontextprotocol/swift-sdk`, module `MCP`) cannot carry the
MPP payment error frame: `MCPError` is a closed enum, `serverError(code:message:)` has no `data`,
and the decoder hardwires `-32042` to `.urlElicitationRequired` (discarding `data.challenges`). We
forked it (`amitach/swift-sdk`) and added an ADDITIVE `MCPError.paymentRequired(code:message:data:)`
case; the decoder disambiguates `-32042`/`-32043` by the presence of `data.challenges`, so existing
behavior is unchanged. The identical patch is upstream as `modelcontextprotocol/swift-sdk#229`.
- Validated on macOS (Swift 6.3, 557 tests) and Linux (Swift 6.1.3, 476 tests; Apple-only transport
  tests are skipped on Linux).
- We pin `Package.swift` to the immutable fork commit `fe4faf15a7e51888f945ae74481453b172276164`;
  TODO: swap to a tagged upstream release once #229 merges.
- **Swift floor: 6.0 -> 6.2 (user decision).** The SDK's own manifest supports 6.0
  (`Package@swift-6.0.swift`), but its TRANSITIVE graph does not: swift-log 1.13 needs tools 6.2,
  swift-nio 2.100 + eventsource need 6.1. The Linux G1 gate caught this (swift:6.0 resolve failed on
  swift-log). Pinning the transitives down is impractical whack-a-mole, so the package floor is now
  Swift 6.2 (Package.swift tools-version; README/ARCHITECTURE badges; CI containers swift:6.0 ->
  swift:6.2; macOS jobs `xcode-select` the runner's Xcode 26). Verified: full graph + 26 MPPMCP
  tests build/pass on swift:6.2 Linux (6.2.4) and macOS (local 6.3.2). The swift-secp256k1 0.21.1
  pin's "stay on tools 6.0" rationale no longer applies (kept the pin; it is source-vetted).

### JCS canonicalization parity (de-risk spike, done)
The challenge id is HMAC-bound over the JCS-canonical `request`; a verifier re-canonicalizes the
echoed native `request`, so our `JSONValue.canonicalized()` (RFC 8785) must match mppx's
`Json.canonicalize` (ox) byte-for-byte. Verified identical across 5 payloads incl. UTF-16 key sort,
non-BMP emoji (literal), control-char escaping (`\b` short form, lowercase `\u00xx`), and large ints.

### Module shape
`MPPMCP` is rail-agnostic: it composes `MPPServer` (mint/verify) + `MPPClient` (method seam) over
`MPPCore` types, and depends on `MCP`. It does NOT depend on `MPPTempo` or any Rust; the payment
method (e.g. the Tempo zero-amount proof) is injected by the consumer. Tests/conformance use the
Tempo proof method, so the TEST target pulls MPPTempo/MPPTempoServer/MPPEVM.

### Wire frame captured (codec is built against real mppx bytes, not interpretation)
Drove mppx 0.6.28's `Mppx.create({..., transport: Transport.mcp()}).charge({amount:'0'})(jsonRpcRequest)`
to capture the exact `-32042` frame (saved: `Tests/MPPMCPTests/Fixtures/mppx-mcp-challenge.json`).
Confirmed shape:
- `error.data` = `{ httpStatus:402, challenges:[<native challenge>], problem:{type,title,status,detail,challengeId} }`.
- challenge native object = `{ id, realm, method, intent, request:<native object>, expires, description }`;
  NO `digest` (omitted over MCP), no `opaque` when unset.
- `request` is a NATIVE JSON object (e.g. `{currency, recipient, amount, methodDetails:{chainId}}`),
  not base64url. So the codec must decode our `Challenge.request` (EncodedJSON) to a native object on
  emit, and re-wrap mppx's native request into `EncodedJSON(json:)` on parse (JCS parity proven, so
  the HMAC id recomputes identically).
- `expires` is RFC 3339 with ms + `Z`; it is NOT bound into the HMAC id, so format differences are safe.
- The fixture has live `id`/`expires`; volatile fields get normalized when wired into a test.

### Module built (per-file under G0-G3.6)
- `MCPValueBridge` (`JSONValue` <-> `MCP.Value`, fail-closed on double/data, preserving the
  integer-only invariant), `MCPPaymentConstants`, `MCPPaymentCodec` (the native-JSON <-> EncodedJSON
  mapping; Receipt/ProblemDetails via Data-hop reuse of their Codable), `MCPPaymentServer.gated`
  (reuses `MPPServerMiddleware.evaluate` via the `Credential.headerValue` adapter; -32042 no-cred,
  -32043 rejected; receipt -> `result._meta`), `MCPPaymentClient` (reuses lifted `selectPaymentMethod`;
  one bounded retry; `RequestContext` overload to preserve `result._meta`).
- Lifted `PaymentClient.select(from:)` -> public `selectPaymentMethod(for:from:)` in MPPClient
  (shared by HTTP + MCP clients; no duplication). MPPClient's 29 tests still green (no behavior change).

### G7.5 peer test-parity (mined wevm/mppx `mcp-sdk/{server/Transport,client/McpClient}.test.ts`)
Ported the union: gate-level (no-credential -> -32042 + challenge in error.data; missing credential
key -> no credential; valid -> proceed + receipt in result._meta with challengeId; replayed -> -32043
+ problem; receipt-attach preserves existing _meta + content) and client-level (pass-through when no
payment; tool-level isError passes through; non-payment MCPError rethrown; no-supporting-method).
DIVERGENCE (G3.5, recorded): mppx skips EXPIRED challenges client-side before signing; our shared
`selectPaymentMethod` does NOT filter by expiry -- the server is the expiry authority (it rejects an
expired credential), consistent with our existing HTTP `PaymentClient`. Porting client-side
expiry-skip would thread a clock into shared selection and change HTTP-client behavior; deferred as a
cross-client follow-up, not an MCP-only patch.

## Verification log
- DONE: package resolves with the fork pin (identity `swift-sdk` @ fe4faf1); `swift build` links
  `MCP` + compiles MPPMCP on macOS (Swift 6.3); 6.0 floor held (no tools-version bump).
- DONE: 26 MPPMCP tests green (bridge 5, codec 9, gate 5, client 3, e2e 3, constants 1); full suite
  515 green, no regressions (MPPClient's 29 unchanged after the select lift). swiftformat +
  swiftlint --strict clean; no em dashes.
- DONE: full graph + 26 MPPMCP tests build/pass on swift:6.2 Linux (6.2.4) and macOS (local 6.3.2).
- DONE: README/ARCHITECTURE updated (Swift 6.2 floor, MPPMCP module rows); CI migrated to 6.2.
- DONE (live cross-SDK conformance, FORWARD): the reference mppx `mcp-sdk` CLIENT pays OUR Swift
  MCP server (`MPPMCPConformanceServer`, an MCP.Server over stdio gating a `premium` tool via the
  MPPMCP gate + TempoProofVerifier), which the Node client spawns over a real stdio transport.
  mppx reads our -32042 challenge, builds the Tempo proof credential, sends it in `params._meta`,
  our server verifies + mints a receipt into `result._meta`, mppx reads it. PASSES live
  (`Scripts/conformance/run-mcp.sh` + `mcp-client.mjs`); wired into the `conformance` CI job.
  Added `@modelcontextprotocol/sdk` (>=1.25.0) to the dev-only harness (npm ci --ignore-scripts).
- DONE (live cross-SDK conformance, REVERSE): OUR Swift MCP client (`MPPMCPConformanceClient`)
  spawns the reference mppx `mcp-sdk` SERVER (`mcp-server.mjs`, McpServer + Transport.mcpSdk() +
  StdioServerTransport) over a real stdio transport and pays its gated tool. Our client reads
  mppx's -32042, builds the Tempo proof credential, sends it in `params._meta`, mppx verifies +
  mints a receipt, our client reads it. PASSES live (`run-mcp-reverse.sh`); wired into the
  `conformance` CI job. BOTH directions now proven live against the real peer, in CI.
  The Swift client wires `MCP.StdioTransport` to the spawned server's pipes (Process + custom FDs).
