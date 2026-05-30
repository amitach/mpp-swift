import Foundation
import MPPCore

/// Builds the `Payment-Receipt` for a Tempo session action as a ``Receipt`` whose
/// ``Receipt/extras`` carry the session-specific fields, matching the reference
/// SDKs' session receipt: `intent`, `challengeId`, `channelId`, `acceptedCumulative`,
/// `spent`, `units`, and (on close) the settlement `txHash`. The base `reference`
/// is the channel id, so a plain `Receipt` consumer still gets a meaningful value.
enum SessionReceipt {
    /// `0x`-prefixed lowercase hex of a 32-byte channel id.
    static func channelHex(_ channelID: Data) -> String {
        "0x" + channelID.map { String(format: "%02x", $0) }.joined()
    }

    static func make(
        method: MethodName,
        now: Date,
        challengeID: String,
        channel: ChannelState,
        txHash: String? = nil
    ) -> Receipt {
        let channelID = channelHex(channel.channelID)
        // Field types mirror the reference session receipt: every field is a JSON
        // string except `units`, a JSON integer (mpp-rs `units: Option<u64>`).
        var extras: [String: Receipt.ReceiptValue] = [
            "intent": .string("session"),
            "challengeId": .string(challengeID),
            "channelId": .string(channelID),
            "acceptedCumulative": .string(channel.highestVoucherAmount.decimalString),
            "spent": .string(channel.spent.decimalString),
            "units": .int(Int64(clamping: channel.units)),
        ]
        if let txHash { extras["txHash"] = .string(txHash) }
        return Receipt(
            method: method,
            timestamp: RFC3339DateTime(date: now),
            reference: channelID,
            extras: extras
        )
    }
}
