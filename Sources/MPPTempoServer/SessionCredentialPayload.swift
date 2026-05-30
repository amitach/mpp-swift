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
struct OpenFields: Hashable {
    let channelID: Data
    let cumulativeAmount: String
    let signature: Data
    let transaction: Data
    /// The signer the client asserts; the server uses the on-chain value, falling
    /// back to the payer, so this is advisory.
    let authorizedSigner: EthereumAddress?
}

/// The fields of a channel top-up credential payload.
struct TopUpFields: Hashable {
    let channelID: Data
    let additionalDeposit: String
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
            guard let voucher = signedVoucher(payload),
                  let transaction = hex(payload["transaction"]) else { return nil }
            let signer = payload["authorizedSigner"]?.stringValue
                .flatMap(EthereumAddress.init(hex:))
            return .open(OpenFields(
                channelID: voucher.channelID, cumulativeAmount: voucher.cumulativeAmount,
                signature: voucher.signature, transaction: transaction, authorizedSigner: signer
            ))
        case "topUp":
            guard let channelID = hex(payload["channelId"]),
                  let additionalDeposit = payload["additionalDeposit"]?.stringValue,
                  let transaction = hex(payload["transaction"]) else { return nil }
            return .topUp(TopUpFields(
                channelID: channelID, additionalDeposit: additionalDeposit, transaction: transaction
            ))
        default: return nil
        }
    }

    /// The `{channelId, cumulativeAmount, signature}` shared by voucher and close.
    private static func signedVoucher(_ payload: [String: JSONValue]) -> SignedVoucherFields? {
        guard let channelID = hex(payload["channelId"]),
              let cumulativeAmount = payload["cumulativeAmount"]?.stringValue,
              let signature = hex(payload["signature"]) else { return nil }
        return SignedVoucherFields(
            channelID: channelID, cumulativeAmount: cumulativeAmount, signature: signature
        )
    }

    /// Decodes a `0x`-prefixed hex JSON string to bytes.
    private static func hex(_ value: JSONValue?) -> Data? {
        value?.stringValue.flatMap(Data.init(hexPrefixed:))
    }
}
