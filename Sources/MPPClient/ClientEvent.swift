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
    ///
    /// - Warning: the ``Credential`` carries the method's secret proof material.
    ///   A handler must not log or persist it; observe only non-secret identifiers.
    case credentialCreated(Credential)
    /// The paid retry returned; carries the `Payment-Receipt` if the server sent one.
    case paymentResponse(receipt: Receipt?)
    /// The flow rejected the request before completing payment.
    case paymentFailed(PaymentClientError)
}
