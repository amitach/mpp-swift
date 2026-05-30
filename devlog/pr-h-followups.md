# PR-H follow-ups (deferred channel-client work)

Tracking doc for the scoped follow-ups deferred out of PR-H (the `tempo`/`session`
402-server channel-payment client, `TempoChannelMethod`). Each is its own PR. All are
faithful ports of mppx 0.6.28 `client/{Session,ChannelOps}.ts`; cite the spec, not the
peer, in shipped code. References below are to the mppx source for the implementer.

Status legend: TODO / IN PROGRESS / DONE.

---

## FU-1: tryRecoverChannel (attach to an existing on-chain channel) - TODO

When there is no in-memory entry for a key AND the challenge suggests a `channelId`
(`methodDetails.channelId`), read the channel on-chain; if `deposit > 0 && !finalized`,
attach with `cumulativeAmount = settled` rather than opening a fresh channel.

- mppx reference: `ChannelOps.ts:217-239` (`tryRecoverChannel`), `Session.ts:149-176`.
- Deferred because it makes the client RPC-dependent; PR-H kept the method RPC-free behind
  the builder seam.
- Plan:
  - New read-only seam `ChannelStateReading` in `MPPTempo`:
    `func onChainChannel(channelID:escrow:chainID:) async throws -> OnChainChannel?`.
    `OnChainChannel` already lives in `MPPTempo` (PR-C); the read already exists in
    `RPCChannelStateProvider` / `EVMRPC` (wrap it; no new RPC code).
  - Inject it OPTIONALLY into `TempoChannelMethod` (nil -> recovery off, today's behavior).
  - Decode `methodDetails.channelId` in `TempoChargeRequest` (one optional field, like
    `suggestedDeposit`).
  - Registry: on miss + suggested id + reader present -> recover-or-open. Match mppx's
    "channel cannot be reused (closed or not found)" error when an explicit context
    channelId fails to recover.
  - Tests: stub reader returns live / finalized / absent; assert attach-with-settled vs
    open-fresh vs the reuse error.
- Scope: medium. Risk: low (read-only, opt-in, default unchanged).

## FU-2: client-initiated topUp / close - TODO

The 402 auto-charge path only opens + vouchers. mppx's manual mode also builds `topUp`
and `close` credentials the server relays/settles.

- mppx reference: `Session.ts:213-342` (manual mode), `ChannelOps.ts:97-120`
  (`createClosePayload`).
- topUp: `[approve, topUp]` tx via `FFITempoTxBuilder.buildTopUpTransaction` (already
  exists); payload `{action:topUp, type:transaction, channelId, transaction,
  additionalDeposit}` (`Session.ts:273-284`). NOTE: `additionalDeposit` is `uint256` per
  the escrow ABI, not `uint128` (see `reference_tempo_escrow_write_abi`).
- close: sign a voucher; payload `{action:close, channelId, cumulativeAmount, signature}`
  (no tx; the server settles).
- Plan:
  - Mirror the open seam: add `TempoTopUpTxBuilder` protocol in `MPPTempo`;
    `FFITempoTxBuilder` conforms (the method already exists).
  - These are client-initiated, not 402 responses, so expose explicit methods on
    `TempoChannelMethod` (`buildTopUp(...)`, `buildClose(...)`) returning a `Credential`
    and updating the registry entry (topUp raises tracked deposit; close marks the entry
    closed, `Session.ts:298-336`).
  - Tests: payload shapes match `SessionAction.parse`'s `topUp`/`close`; registry
    deposit/closed bookkeeping; voucher verifies.
- Scope: medium. Risk: low-medium (new public surface; the uint256 vs uint128 gotcha).

## FU-3: separate access-key authorizedSigner - TODO

A distinct secp256k1 access key signs vouchers while the root account funds the channel,
so payer != authorizedSigner != voucher-signing key. PR-H assumes all three are one wallet.

- mppx reference: `Session.ts:82-84`
  (`getAuthorizedSigner = parameters.authorizedSigner ?? account.accessKeyAddress`),
  `ChannelOps.ts:137` (open uses `options.authorizedSigner ?? account.address`).
- Plan:
  - Optional `voucherSigner: Secp256k1Signer` (the access key) on `TempoChannelMethod`;
    default = the funding signer (today's behavior).
  - Thread `authorizedSigner = voucherSigner.address` into `Channel.Parameters`,
    `TempoOpenParameters`, and the open/voucher payloads; sign vouchers with `voucherSigner`.
    The funding key stays in the injected open builder.
  - Tests: open params + payload carry the access-key address as `authorizedSigner`;
    vouchers recover to the access key, not the payer; `Channel.id` reflects it.
- Scope: small-medium. Risk: low.

---

## Sequencing

- All three are independent of PR-H.2 (cross-SDK conformance) and of each other.
- FU-3 is the one most likely to be exercised by PR-H.2 if mppx's conformance server issues
  access-key challenges; confirm during H.2 setup and, if so, do FU-3 first.
- Suggested order: PR-H.2, then FU-1 -> FU-2 -> FU-3.

## Also still open (PR-G, TempoChannelSession, not the client method)

- Test `close()` with no prior voucher.
- Test retry-after-revert.
