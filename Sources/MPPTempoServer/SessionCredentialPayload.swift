import Foundation
import MPPCore
import MPPEVM

/// The fields of a signed voucher carried in a session credential payload (the
/// `voucher` and `close` actions).
struct SignedVoucherFields: Hashable {
    let channelID: Data
    let cumulativeAmount: String
    let signature: Data
}

/// The fields of a channel-open credential payload.
///
/// The wire also carries `authorizedSigner` (the signer the client asserts), but the server
/// derives the authorized signer from the on-chain channel (falling back to the payer) rather
/// than trusting the client's assertion, so it is advisory and not stored here.
struct OpenFields: Hashable {
    let channelID: Data
    let cumulativeAmount: String
    let signature: Data
    let transaction: Data
}

/// The fields of a channel top-up credential payload.
///
/// The wire also carries `additionalDeposit`, but the server settles the new
/// deposit from the on-chain value `broadcastTopUp` reports rather than the
/// client's asserted amount, so it is not carried here; it is only required to
/// be present as a well-formedness check (see ``SessionAction/parse(_:)``).
struct TopUpFields: Hashable {
    let channelID: Data
    let transaction: Data
}

/// A parsed Tempo session credential payload: one of the four channel-lifecycle
/// actions (`open`, `topUp`, `voucher`, `close`).
enum SessionAction: Hashable {
    case open(OpenFields)
    case topUp(TopUpFields)
    case voucher(SignedVoucherFields)
    case close(SignedVoucherFields)

    /// Parses the action from a credential payload, or `nil` if the `action` is
    /// missing/unknown or a required field is absent or malformed.
    static func parse(_ payload: [String: JSONValue]) -> SessionAction? {
        guard let action = payload["action"]?.stringValue else { return nil }
        switch action {
        case "voucher": return signedVoucher(payload).map(SessionAction.voucher)
        case "close": return signedVoucher(payload).map(SessionAction.close)
        case "open":
            // `authorizedSigner` is advisory (the server reads the signer on-chain), so like
            // `additionalDeposit` below it is not parsed or stored.
            guard let voucher = signedVoucher(payload),
                  let transaction = hex(payload["transaction"]) else { return nil }
            return .open(OpenFields(
                channelID: voucher.channelID, cumulativeAmount: voucher.cumulativeAmount,
                signature: voucher.signature, transaction: transaction
            ))
        case "topUp":
            // `additionalDeposit` is required on the wire but advisory to the server
            // (the deposit is read on-chain), so it is checked for presence, not stored.
            guard let channelID = hex(payload["channelId"]),
                  payload["additionalDeposit"]?.stringValue != nil,
                  let transaction = hex(payload["transaction"]) else { return nil }
            return .topUp(TopUpFields(channelID: channelID, transaction: transaction))
        default: return nil
        }
    }

    /// The `{channelId, cumulativeAmount, signature}` shared by voucher, close, and open.
    ///
    /// The signature is normalized through ``SignatureEnvelope`` at this deserialize boundary: a
    /// Tempo magic trailer is stripped and only a bare 65-byte secp256k1 signature is accepted, so
    /// everything downstream (verify, the stored highest voucher, and the on-chain settle relay)
    /// sees the canonical bytes the escrow's `ecrecover` redeems. A keychain- or otherwise-wrapped
    /// signature fails here and the action is rejected.
    private static func signedVoucher(_ payload: [String: JSONValue]) -> SignedVoucherFields? {
        guard let channelID = hex(payload["channelId"]),
              let cumulativeAmount = payload["cumulativeAmount"]?.stringValue,
              let rawSignature = hex(payload["signature"]),
              let signature = SignatureEnvelope.canonicalVoucherSignature(rawSignature)
        else { return nil }
        return SignedVoucherFields(
            channelID: channelID, cumulativeAmount: cumulativeAmount, signature: signature
        )
    }

    /// Decodes a `0x`-prefixed hex JSON string to bytes.
    private static func hex(_ value: JSONValue?) -> Data? {
        value?.stringValue.flatMap(Data.init(hexPrefixed:))
    }
}
