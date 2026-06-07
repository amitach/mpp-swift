import Foundation
import MPPCore
import MPPEVM
import MPPX402

/// An ``X402Settlement`` that settles through an x402 facilitator (``X402Facilitator``): it
/// reconstructs the x402 PaymentPayload and PaymentRequirements from the authorization + token
/// domain, posts them to the facilitator's `/settle`, and returns the settled transaction hash.
///
/// This is x402's native, gasless-for-everyone model -- the resource server delegates the on-chain
/// submit to the facilitator (Coinbase's or self-hosted). The negotiated `version` controls the
/// wire form. Plug it into ``X402ChargeVerifier``.
public struct FacilitatorSettlement: X402Settlement {
    private let facilitator: X402Facilitator
    private let version: X402Version
    private let maxTimeoutSeconds: UInt64

    /// Creates the settler.
    /// - Parameters:
    ///   - facilitator: the facilitator client.
    ///   - version: the negotiated x402 version the payload/requirements are encoded for.
    ///   - maxTimeoutSeconds: the resource server's settlement-timeout hint, carried into the
    ///     reconstructed requirements. It is not signature-bound and cannot be recovered from the
    ///     authorization, so the verifier supplies it from the original challenge. Defaults to
    ///     ``X402ChargeMethod/defaultTimeoutSeconds``.
    public init(
        facilitator: X402Facilitator,
        version: X402Version = .v1,
        maxTimeoutSeconds: UInt64 = X402ChargeMethod.defaultTimeoutSeconds
    ) {
        self.facilitator = facilitator
        self.version = version
        self.maxTimeoutSeconds = maxTimeoutSeconds
    }

    public func settle(
        authorization: X402Authorization, domain: X402Domain, signature: Data
    ) async throws -> String {
        let network = X402Network(chainId: domain.chainId)
        let exact = X402ExactPayload(authorization: authorization, signature: signature)
        let payment = X402PaymentPayload(
            version: version, scheme: "exact", network: network, payload: exact
        )
        // Reconstruct the requirements the payer signed against. maxTimeoutSeconds is a server
        // policy hint, not signature-bound and not recoverable from the authorization (validAfter
        // is 0 in the common case, so validBefore - validAfter is an absolute timestamp, not a
        // duration), so it is carried from the configured value rather than re-derived.
        let requirements = X402PaymentRequirements(
            scheme: "exact",
            network: network,
            amount: authorization.value,
            asset: domain.asset.checksummed,
            payTo: authorization.recipient.checksummed,
            maxTimeoutSeconds: maxTimeoutSeconds,
            extra: ["name": .string(domain.name), "version": .string(domain.version)]
        )
        let response = try await facilitator.settle(payment: payment, requirements: requirements)
        guard response.success else {
            throw FacilitatorSettlementError.settlementFailed(
                response.errorReason ?? "facilitator reported failure"
            )
        }
        return response.transaction
    }
}

/// A reason ``FacilitatorSettlement`` could not settle.
public enum FacilitatorSettlementError: Error, Sendable, Hashable {
    /// The facilitator reported the settlement did not succeed (carries its `errorReason`).
    case settlementFailed(String)
}
