# B7: SignatureEnvelope normalization - implementation notes

## What B7 is
The backlog's last open WS-10 item: normalize an inbound voucher signature at the
transport/deserialize boundary before it reaches the (deliberately strict) canonical-65-byte
`Voucher.verify`. Specifically: **strip the 32-byte Tempo magic trailer** and **reject keychain
(and other typed) envelopes**, since the escrow contract redeems a voucher via `ecrecover`, which
accepts only a raw secp256k1 signature.

## Why it was parked here (not in the crypto primitive)
An earlier decision (#30, plan §7a/D-F) kept `Voucher.verify` canonical-only: it *rejects* a
magic-suffixed or keychain signature rather than stripping. The reasoning held: both reference SDKs
*produce* clean signatures, and the magic trailer is a transport artifact of local-account RPC
routing. The envelope tolerance was deferred to this boundary item so the primitive stays a clean,
anti-malleability-strict crypto check while the transport layer absorbs envelope variation.

## Peer-verified byte rules
Verified against the canonical Tempo signature-envelope format (`ox/tempo` `SignatureEnvelope`,
which both reference SDKs use), read at source:
- `magicBytes` = 32 bytes of `0x77`, a **trailer**: deserialize strips it when the value ends with
  it (`value.endsWith(magic) ? slice(0, -32) : value`).
- After stripping, **size 65 = bare secp256k1** (no type prefix). Otherwise the first byte is a
  type id: `0x01` p256, `0x02` webAuthn, `0x03`/`0x04` keychain (`userAddress(20) + inner`).
- The reference voucher verify rejects keychain and any non-secp256k1 type (the escrow `ecrecover`s
  a raw 65-byte signature).

So the voucher-boundary rule reduces exactly to: **strip a trailing `0x77`x32, then accept only a
bare 65-byte secp256k1; reject every typed envelope.**

## Implementation
- `Sources/MPPEVM/SignatureEnvelope.swift`: a pure `SignatureEnvelope.canonicalVoucherSignature(_:)
  -> Data?`. Strips the trailer only when `count > 32 && suffix(32) == magic` (so a value that is
  *only* the trailer is not mistaken for an empty signature), then returns the bytes iff they are
  exactly 65, else `nil`.
- `Sources/MPPTempoServer/SessionCredentialPayload.swift`: normalize once in `signedVoucher(_:)`,
  the single decode point shared by the `voucher`, `close`, and `open` actions. Normalizing here
  (not at the verify call site) means verify, the stored highest voucher, and the on-chain settle
  relay all see the canonical bytes; a non-normalizable signature fails to parse and the action is
  rejected.
- `Voucher.verify` is unchanged (still canonical-65-only).

## Behavior delta
A magic-suffixed voucher signature that today is rejected is now stripped at the boundary and
accepted if the underlying 65 bytes recover to the expected signer. Keychain/p256/webAuthn are
still rejected. This is exactly the leniency B7 was scoped to add; the crypto primitive is
untouched.

## Safety
Stripping can only *remove* a transport artifact from an otherwise-canonical signature; it can
never make an invalid signature recover to a different signer (the recovered address still has to
match in `Voucher.verify`). Tested: a magic-suffixed real signature normalizes and verifies for the
true signer but still fails for a different expected signer; a 64-byte-ending-in-trailer or
bare-trailer value strips to a non-65 length and is rejected; typed envelopes are rejected.

## Tests
- `Tests/MPPEVMTests/SignatureEnvelopeTests.swift`: passthrough, strip+verify, strip-does-not-forge,
  keychain reject (with and without trailer), p256-typed reject, bare-trailer reject,
  short-after-strip reject, wrong-length reject.
- `Tests/MPPTempoServerTests/SessionCredentialPayloadTests.swift`: the parse boundary - canonical
  unchanged, magic stripped (voucher and close actions), keychain rejected (parse fails).
- The existing `VoucherTests.verifyRejectsMagicSuffixed` / `verifyRejectsKeychainEnvelope` are
  retained unchanged: the primitive still rejects, which is correct.

## Not built (subtraction)
Keychain *unwrap* (extracting the inner secp256k1 from a `0x03` envelope): the reference SDK does
this only on its *signing* side when an access key is the authorized signer, not on voucher verify.
We have no such consumer (the escrow rejects keychain for vouchers), so it is omitted rather than
added speculatively. No FFI/release change: this is pure Swift at the message-signing/transport
layer.
