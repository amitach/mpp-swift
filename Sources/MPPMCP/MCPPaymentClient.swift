import MCP
import MPPClient
import MPPCore

/// Pays a payment-gated MCP `tools/call` transparently, on the client side of the JSON-RPC / MCP
/// transport binding.
///
/// It wraps an MCP `Client`: a first call is made without a credential; if the server answers with
/// `MCPError.paymentRequired` (`-32042`), the offered challenges are read from `error.data`, the
/// first one a registered `PaymentMethodClient` supports is selected (the same selection rule the
/// HTTP flow uses), a credential is built and placed in `params._meta`, and the call is retried
/// once. The minted receipt is read back from `result._meta`.
public struct MCPPaymentClient: Sendable {
    private let client: Client
    private let methods: [any PaymentMethodClient]

    /// - Parameters:
    ///   - client: a connected MCP `Client`.
    ///   - methods: the payment methods to pay an offered challenge with, in preference order.
    public init(client: Client, methods: [any PaymentMethodClient]) {
        self.client = client
        self.methods = methods
    }

    /// The result of a (possibly paid) tool call: the tool result, plus the receipt if one was
    /// minted (a call that needed no payment, or a server that minted none, has a `nil` receipt).
    public struct PaidResult: Sendable {
        public let result: CallTool.Result
        public let receipt: Receipt?
    }

    /// Calls `name`, paying a `-32042` challenge transparently if one is raised.
    ///
    /// - Throws: the underlying `MCPError` if no registered method supports the offered challenges,
    ///   or if the retried call is itself rejected (a single retry; no payment loop).
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> PaidResult {
        do {
            let result = try await send(name: name, arguments: arguments, meta: nil)
            return try PaidResult(result: result, receipt: Self.receipt(from: result._meta))
        } catch let error as MCPError {
            guard case let .paymentRequired(_, _, data) = error else { throw error }
            let challenges = try MCPPaymentCodec.challenges(fromErrorData: data)
            guard let selection = selectPaymentMethod(for: challenges, from: methods) else {
                throw error
            }
            let credential = try await selection.method.buildCredential(for: selection.challenge)
            let meta = try Metadata(additionalFields: [
                MCPPayment.credentialMetaKey: MCPPaymentCodec.value(for: credential),
            ])
            let result = try await send(name: name, arguments: arguments, meta: meta)
            return try PaidResult(result: result, receipt: Self.receipt(from: result._meta))
        }
    }

    /// Sends one `tools/call` and awaits the full `CallTool.Result` (the `RequestContext` overload,
    /// which preserves `result._meta`; the tuple overload drops it).
    private func send(
        name: String,
        arguments: [String: Value]?,
        meta: Metadata?
    ) async throws -> CallTool.Result {
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: name, arguments: arguments, meta: meta
        )
        return try await context.value
    }

    private static func receipt(from meta: Metadata?) throws -> Receipt? {
        guard let value = meta?[MCPPayment.receiptMetaKey] else { return nil }
        return try MCPPaymentCodec.receipt(from: value)
    }
}
