import MPPServer
import Testing
@testable import MPPTempoServer

// §10.5: every session rejection maps to a distinct RFC 9457 problem type and HTTP status,
// matching the mppx peer's taxonomy, rather than collapsing to one generic 402.
@Suite("SessionError problem taxonomy")
struct SessionErrorProblemTests {
    private typealias SErr = SessionMethod.SessionError
    private struct Expected { let slug: String; let status: Int }

    @Test("each session error maps to its RFC 9457 problem slug and HTTP status")
    func mapsEachCase() {
        let cases: [(SErr, Expected)] = [
            (.malformedPayload, Expected(slug: "bad-request", status: 400)),
            (.malformedRequest, Expected(slug: "bad-request", status: 400)),
            (.missingEscrow, Expected(slug: "bad-request", status: 400)),
            (
                .channelClosed(reason: "pending close"),
                Expected(slug: "session/channel-finalized", status: 410)
            ),
            (.channelNotFound, Expected(slug: "session/channel-not-found", status: 410)),
            (.belowSettled, Expected(slug: "verification-failed", status: 402)),
            (.belowHighestVoucher, Expected(slug: "verification-failed", status: 402)),
            (.onChainMismatch(reason: "payee"), Expected(slug: "verification-failed", status: 402)),
            (.exceedsDeposit, Expected(slug: "session/amount-exceeds-deposit", status: 402)),
            (.invalidVoucherSignature, Expected(slug: "session/invalid-signature", status: 402)),
            (.deltaTooSmall, Expected(slug: "session/delta-too-small", status: 402)),
            (.insufficientBalance, Expected(slug: "session/insufficient-balance", status: 402)),
        ]
        for (error, expected) in cases {
            let problem = error.settlementProblem
            #expect(problem.slug == expected.slug)
            #expect(problem.status == expected.status)
            #expect(!problem.title.isEmpty)
            #expect(!problem.detail.isEmpty)
        }
    }

    @Test("the channel-closed reason is carried into the detail for diagnostics")
    func channelClosedCarriesReason() {
        let problem = SErr.channelClosed(reason: "deposit is zero (settled)").settlementProblem
        #expect(problem.detail.contains("deposit is zero (settled)"))
        #expect(problem.status == 410)
    }
}
