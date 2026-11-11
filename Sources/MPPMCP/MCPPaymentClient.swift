import MCP
import MPPClient
import MPPCore

/// Pays a payment-gated MCP `tools/call` transparently, on the client side of the JSON-RPC / MCP
/// transport binding.
///
/// It wraps an MCP `Client`: a first call is made without a credential. If the server answers with
/// a payment JSON-RPC error whose structured `error.data` the official SDK preserved
/// (`MCPError.serverErrorWithData` whose code is ``MCPPayment/paymentRequiredCode`` or
/// ``MCPPayment/verificationFailedCode``), the offered challenges are read from `data.challenges`,
/// the first one a registered `PaymentMethodClient` supports is selected (the same selection rule
/// the HTTP flow uses), a credential is built and placed in `params._meta`, and the call is
/// retried once. The minted receipt is read back from `result._meta`.
///
/// Decode gap (`modelcontextprotocol/swift-sdk` #291): every `-32042` decodes as
/// `MCPError.urlElicitationRequired`, and only `data.elicitations` is kept. `data.challenges` is
/// dropped before this client sees the error. The peer-compatible default, and every absent
/// credential (including ``MCPErrorCodeMode/specCorrect``), uses `-32042`, so this client cannot
/// pay that challenge after it has passed through `MCPError`'s decoder. This type does not
/// reinterpret `-32042` as a payment error and does not add an `MCPError` case. The server still
/// emits the challenge frame on the wire; a peer that reads the raw JSON-RPC object (mppx) sees
/// it. `-32043` decodes as `serverErrorWithData` and is payable here.
public struct MCPPaymentClient: Sendable {
    private let client: Client
    private let methods: [any PaymentMethodClient]
    private let authorizer: any PaymentAuthorizer

    /// - Parameters:
    ///   - client: a connected MCP `Client`.
    ///   - methods: the payment methods to pay an offered challenge with, in preference order.
    ///   - authorizer: consulted once after a challenge is selected and before its credential is
    ///     built; throwing denies the payment. Defaults to ``AllowAllAuthorizer`` (ungated, the
    ///     prior behavior). The same seam the HTTP `PaymentClient` uses, so one injected authorizer
    ///     gates both transports identically.
    public init(
        client: Client,
        methods: [any PaymentMethodClient],
        authorizer: any PaymentAuthorizer = AllowAllAuthorizer()
    ) {
        self.client = client
        self.methods = methods
        self.authorizer = authorizer
    }

    /// The result of a (possibly paid) tool call: the tool result, plus the receipt if one was
    /// minted (a call that needed no payment, or a server that minted none, has a `nil` receipt).
    public struct PaidResult: Sendable {
        public let result: CallTool.Result
        public let receipt: Receipt?
    }

    /// Calls `name`, paying a preserved payment-challenge `error.data` transparently if one is
    /// raised. A `-32042` that the SDK decoded as URL elicitation is rethrown (see the type
    /// discussion of the decode gap).
    ///
    /// - Throws: the underlying `MCPError` if no registered method supports the offered challenges,
    ///   or if the retried call is itself rejected (a single retry; no payment loop); an authorizer
    ///   denial propagates unwrapped. A payment code whose `error.data` is not an object is
    ///   rethrown as the original `MCPError`.
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> PaidResult {
        do {
            let result = try await send(name: name, arguments: arguments, meta: nil)
            return try PaidResult(result: result, receipt: Self.receipt(from: result._meta))
        } catch let error as MCPError {
            guard let data = Self.preservedPaymentData(from: error) else { throw error }
            let challenges = try MCPPaymentCodec.challenges(fromErrorData: data)
            guard let selection = selectPaymentMethod(for: challenges, from: methods) else {
                throw error
            }
            // Consult the authorizer before the method signs anything; a denial throws unwrapped.
            try await authorizeSelection(
                method: selection.method, challenge: selection.challenge, with: authorizer
            )
            let credential = try await selection.method.buildCredential(for: selection.challenge)
            let meta = try Metadata(additionalFields: [
                MCPPayment.credentialMetaKey: MCPPaymentCodec.value(for: credential),
            ])
            let result = try await send(name: name, arguments: arguments, meta: meta)
            return try PaidResult(result: result, receipt: Self.receipt(from: result._meta))
        }
    }

    /// `error.data` when `error` is a payment code the official SDK kept as structured data.
    ///
    /// Returns nil for `.urlElicitationRequired` (the decoded form of `-32042`) and for any
    /// non-payment code, including a payment code whose `data` is not a JSON object.
    private static func preservedPaymentData(from error: MCPError) -> [String: Value]? {
        guard case let .serverErrorWithData(code, _, data) = error,
              code == MCPPayment.paymentRequiredCode || code == MCPPayment.verificationFailedCode,
              let object = data.objectValue
        else { return nil }
        return object
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
