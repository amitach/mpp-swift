import Foundation
import MPPCore
import MPPEVM
import MPPTempo

// File-scope internals factored out of SessionMethod.swift to keep it under the length limits.
// Module-internal (not `private`) only because they live in a separate file; SessionMethod is the
// sole constructor/consumer.

/// Per-request resolved context for a session action: the challenge's route, the
/// resolved charge amount, and the injected clock. (The minimum voucher delta is
/// resolved separately on the voucher path, the only action that uses it.)
struct SessionContext {
    let method: MethodName
    let challengeID: String
    let escrow: EthereumAddress
    let chainID: UInt64
    let chargeAmount: ChannelAmount
    let recipient: EthereumAddress?
    let currency: EthereumAddress?
    let now: Date
}

/// Picks the voucher a `close` settles: the higher of the client's final voucher
/// and the server's stored highest accepted voucher (with its stored signature), so
/// a close can never settle below what the channel already drew. The final `else` is
/// unreachable (a stored highest above the client's amount always carries its
/// signature) and falls back to the already-verified client voucher defensively.
func settleSelection(
    clientCumulative: ChannelAmount, clientSignature: Data, claimed: ChannelState
) -> (amount: ChannelAmount, signature: Data) {
    if clientCumulative >= claimed.highestVoucherAmount {
        return (clientCumulative, clientSignature)
    }
    if let storedSignature = claimed.highestVoucherSignature {
        return (claimed.highestVoucherAmount, storedSignature)
    }
    return (clientCumulative, clientSignature)
}

extension OpenFields {
    /// The `{channelId, cumulativeAmount, signature}` view for signature verification.
    var asVoucher: SignedVoucherFields {
        SignedVoucherFields(
            channelID: channelID, cumulativeAmount: cumulativeAmount, signature: signature
        )
    }
}
