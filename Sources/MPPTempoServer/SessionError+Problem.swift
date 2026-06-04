import MPPServer

// §10.5: map each session rejection to a distinct RFC 9457 problem and HTTP status (matching the
// mppx peer's taxonomy) instead of collapsing every failure to one generic 402. A malformed
// request is 400 (bad-request), a closed or unknown channel is 410 (gone), and an amount,
// signature, delta, or balance failure is 402 with a session-specific problem type.
extension SessionMethod.SessionError: SettlementProblemConvertible {
    public var settlementProblem: SettlementProblem {
        switch self {
        case .malformedPayload:
            badRequest("The session payload was not a recognized channel action.")
        case .malformedRequest:
            badRequest("The challenge's request parameters were malformed.")
        case .missingEscrow:
            badRequest("The challenge did not carry an escrow contract address.")
        case let .channelClosed(reason):
            SettlementProblem(
                slug: "session/channel-finalized", title: "Channel Closed", status: 410,
                detail: "The payment channel is closed: \(reason)."
            )
        case .channelNotFound:
            SettlementProblem(
                slug: "session/channel-not-found", title: "Channel Not Found", status: 410,
                detail: "No payment channel is recorded for the voucher."
            )
        case .belowSettled:
            verificationFailed("The voucher amount is at or below the on-chain settled amount.")
        case .belowHighestVoucher:
            verificationFailed("The voucher amount is below the highest already accepted.")
        case let .onChainMismatch(reason):
            verificationFailed("The on-chain channel did not match the route: \(reason).")
        case .exceedsDeposit:
            SettlementProblem(
                slug: "session/amount-exceeds-deposit", title: "Amount Exceeds Deposit",
                status: 402, detail: "The voucher amount exceeds the on-chain channel deposit."
            )
        case .invalidVoucherSignature:
            SettlementProblem(
                slug: "session/invalid-signature", title: "Invalid Signature", status: 402,
                detail: "The voucher signature did not recover to the authorized signer."
            )
        case .deltaTooSmall:
            SettlementProblem(
                slug: "session/delta-too-small", title: "Delta Too Small", status: 402,
                detail: "The voucher increase over the previous highest is below the minimum."
            )
        case .insufficientBalance:
            SettlementProblem(
                slug: "session/insufficient-balance", title: "Insufficient Balance",
                status: 402, detail: "The channel's available balance is insufficient."
            )
        }
    }

    private func badRequest(_ detail: String) -> SettlementProblem {
        SettlementProblem(slug: "bad-request", title: "Bad Request", status: 400, detail: detail)
    }

    private func verificationFailed(_ detail: String) -> SettlementProblem {
        SettlementProblem(
            slug: "verification-failed", title: "Verification Failed", status: 402, detail: detail
        )
    }
}
