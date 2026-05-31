import Foundation
import MCP
import MPPCore
import MPPServer

/// Gates an MCP `tools/call` handler behind an MPP payment, on the server side of the JSON-RPC /
/// MCP transport binding.
///
/// It reuses `MPPServerMiddleware` wholesale (the transport-agnostic mint-or-verify pipeline):
/// the credential carried in the request's `params._meta` is adapted to the `Authorization`
/// header string the middleware consumes, the body is empty (MCP carries no HTTP body, so no
/// digest), and the middleware's `Decision` is mapped onto the JSON-RPC wire:
///
/// - no / rejected credential -> `MCPError.paymentRequired` (`-32042` when none was supplied,
///   `-32043` when one was supplied but failed verification), carrying the challenge set in
///   `error.data.challenges`;
/// - verified -> the wrapped handler runs and the minted receipt is attached to `result._meta`.
public struct MCPPaymentServer: Sendable {
    private let middleware: MPPServerMiddleware
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - middleware: the mint/verify pipeline (challenge minter + payment verifier + binding).
    ///   - now: the clock, injected so tests are deterministic; defaults to the system clock.
    public init(middleware: MPPServerMiddleware, now: @escaping @Sendable () -> Date = Date.init) {
        self.middleware = middleware
        self.now = now
    }

    /// Wraps a `tools/call` handler so it requires payment. Register the result with
    /// `server.withMethodHandler(CallTool.self, handler:)`. A handler that gates only some tools
    /// can branch on `params.name` before delegating to its gated and ungated inner handlers.
    public func gated(
        _ inner: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result
    ) -> @Sendable (CallTool.Parameters) async throws -> CallTool.Result {
        let middleware = middleware
        let now = now
        return { params in
            let credential = try Self.credential(from: params._meta)
            let decision = try await middleware.evaluate(
                authorization: credential?.headerValue,
                body: Data(),
                now: now()
            )
            switch decision {
            case .payloadTooLarge:
                // Unreachable: the MCP body is always empty here. Fail closed rather than proceed.
                throw MCPError.internalError("payment gate: unexpected oversized body")
            case let .challenge(challenge, problem):
                let code = credential == nil
                    ? MCPPayment.paymentRequiredCode
                    : MCPPayment.verificationFailedCode
                throw try MCPError.paymentRequired(
                    code: code,
                    message: problem.detail ?? problem.title ?? "Payment Required",
                    data: MCPPaymentCodec.errorData(challenge: challenge, problem: problem)
                )
            case let .proceed(verified):
                let result = try await inner(params)
                guard let receipt = verified.receipt else { return result }
                return try Self.attachReceipt(
                    receipt, challengeID: verified.credential.challenge.id, to: result
                )
            }
        }
    }

    private static func credential(from meta: Metadata?) throws -> Credential? {
        guard let value = meta?[MCPPayment.credentialMetaKey] else { return nil }
        return try MCPPaymentCodec.credential(from: value)
    }

    private static func attachReceipt(
        _ receipt: Receipt,
        challengeID: String,
        to result: CallTool.Result
    ) throws -> CallTool.Result {
        var result = result
        var meta = result._meta ?? Metadata()
        meta.fields[MCPPayment.receiptMetaKey] = try MCPPaymentCodec.value(
            for: receipt, challengeID: challengeID
        )
        result._meta = meta
        return result
    }
}
