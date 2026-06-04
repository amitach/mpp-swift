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
/// - no / rejected credential -> `MCPError.paymentRequired`, carrying the challenge set in
///   `error.data.challenges`; the JSON-RPC code is chosen by ``MCPErrorCodeMode`` (default
///   ``MCPErrorCodeMode/peerCompatible``, which matches the mppx peer - see its
///   DIVERGING_FROM_SPEC note);
/// - verified -> the wrapped handler runs and the minted receipt is attached to `result._meta`.
public struct MCPPaymentServer: Sendable {
    private let middleware: MPPServerMiddleware
    private let codeMode: MCPErrorCodeMode
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - middleware: the mint/verify pipeline (challenge minter + payment verifier + binding).
    ///   - codeMode: which JSON-RPC error code to emit on a payment-required re-challenge;
    ///     defaults to ``MCPErrorCodeMode/peerCompatible`` (matches the mppx peer). Select
    ///     ``MCPErrorCodeMode/specCorrect`` for the `draft-payment-transport-mcp-00` §10.1 codes.
    ///   - now: the clock, injected so tests are deterministic; defaults to the system clock.
    public init(
        middleware: MPPServerMiddleware,
        codeMode: MCPErrorCodeMode = .peerCompatible,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.middleware = middleware
        self.codeMode = codeMode
        self.now = now
    }

    /// Wraps a `tools/call` handler so it requires payment. Register the result with
    /// `server.withMethodHandler(CallTool.self, handler:)`. A handler that gates only some tools
    /// can branch on `params.name` before delegating to its gated and ungated inner handlers.
    public func gated(
        _ inner: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result
    ) -> @Sendable (CallTool.Parameters) async throws -> CallTool.Result {
        let middleware = middleware
        let codeMode = codeMode
        let now = now
        return { params in
            let credential: Credential?
            do {
                credential = try Self.credential(from: params._meta)
            } catch is MCPPaymentCodec.CodecError {
                // A present-but-malformed credential is a client error, not an internal one:
                // answer -32602 (invalid params), matching the reference peer, rather than letting
                // the codec error surface as -32603. (An ABSENT credential returns nil -> -32042.)
                throw MCPError.invalidParams("malformed payment credential")
            }
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
                // The re-challenge code depends on the configured compatibility mode. An ABSENT
                // credential is always -32042; a SUPPLIED-but-rejected one is -32042 in the
                // peer-compatible default (the mppx client only retries on -32042) or -32043 in
                // spec-correct mode. See the DIVERGING_FROM_SPEC note on `MCPErrorCodeMode`.
                let code: Int = switch codeMode {
                case .peerCompatible:
                    MCPPayment.paymentRequiredCode
                case .specCorrect:
                    credential == nil
                        ? MCPPayment.paymentRequiredCode
                        : MCPPayment.verificationFailedCode
                }
                throw try MCPError.paymentRequired(
                    code: code,
                    message: problem.detail ?? problem.title ?? "Payment Required",
                    data: MCPPaymentCodec.errorData(challenge: challenge, problem: problem)
                )
            case let .problem(problem):
                // A terminal §10.5 settlement problem (no retry challenge) only arises for a
                // session method, which the MCP gate never registers (the JSON-RPC binding gates
                // one-shot charge methods, not multi-request channel sessions), so this is
                // unreachable. Fail closed rather than emit a challenge-less error frame that the
                // paired `MCPPaymentClient` cannot parse (it expects a `challenges` array). If MCP
                // ever gains session support, both sides of the codec must learn the terminal form.
                throw MCPError.internalError(
                    "payment gate: unexpected terminal settlement problem (\(problem.title ?? "?"))"
                )
            case let .proceed(verified):
                let result = try await inner(params)
                // MCP payment is always credential-based, so credential is present here. If a
                // future credential-less authorize path reached this point, skip the receipt
                // envelope rather than fabricate a challenge id.
                guard let receipt = verified.receipt,
                      let challengeID = verified.credential?.challenge.id else { return result }
                return try Self.attachReceipt(receipt, challengeID: challengeID, to: result)
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
