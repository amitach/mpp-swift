import MPPClient
import MPPCore

// The `approvalFacts` override lives in this extension (not the main type body) so it does not
// count against `TempoChannelMethod`'s type-body / file length, the same reason
// `channelVoucherPayload` is file-scope.
public extension TempoChannelMethod {
    /// The approval facts for `challenge`, filling amount/currency/recipient from the decoded
    /// session request (the per-charge amount, matching the method's own approval gate). An
    /// undecodable request falls back to the rail-agnostic facts.
    func approvalFacts(for challenge: Challenge) -> PaymentApprovalRequest {
        guard let request = try? TempoChargeRequest(challenge: challenge) else {
            return PaymentApprovalRequest(generic: challenge)
        }
        return PaymentApprovalRequest(
            challengeId: challenge.id, realm: challenge.realm,
            method: challenge.method, intent: challenge.intent,
            amount: request.amount, currency: request.currency, recipient: request.recipient,
            description: challenge.description, expires: challenge.expires
        )
    }
}
