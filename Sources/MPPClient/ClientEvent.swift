import MPPCore

/// An observable moment in the client's 402 payment flow, delivered to the sink
/// a ``PaymentClient`` was created with.
///
/// Diagnostics only: emitting an event never changes the flow, and the sink runs
/// synchronously inside the request path, so a handler should be cheap. (The
/// reference SDKs let a `challenge.received` handler inject a credential; that
/// active hook is deferred. This is observe-only for now.)
public enum ClientEvent: Sendable {
    /// A `402` challenge the client selected to pay.
    case challengeReceived(Challenge)
    /// The credential a payment method built for the selected challenge.
    case credentialCreated(Credential)
    /// The paid retry returned; carries the `Payment-Receipt` if the server sent one.
    case paymentResponse(receipt: Receipt?)
    /// The flow rejected the request before completing payment.
    case paymentFailed(PaymentClientError)
}

/// A flow-level reason the client did not complete a payment.
///
/// These are the ``PaymentClient`` flow's own rejections. An error thrown by the
/// transport or by a payment method propagates to the caller unwrapped (the flow
/// does not relabel another layer's typed error).
public enum PaymentClientError: Error, Sendable, Hashable {
    /// The request URL was not `https` and `allowInsecureLocal` did not permit it.
    case insecureTransport(url: String)
    /// The `402` response carried no parseable `Payment` challenge.
    case malformedChallenge
    /// No registered payment method supports any offered challenge.
    case noSupportedMethod
}
