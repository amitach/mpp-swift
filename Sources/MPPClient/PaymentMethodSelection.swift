import MPPCore

/// Selects the first offered challenge that a registered method supports, with that method.
///
/// Challenges are tried in offered order (q-value ranking is a later refinement). This is the
/// shared selection step of the 402 flow, used by `PaymentClient` (HTTP) and by transport
/// bindings such as the JSON-RPC / MCP client, so the "first supported challenge" rule lives in
/// one place.
///
/// - Returns: the matched method and challenge, or `nil` if no registered method supports any of
///   the offered challenges.
public func selectPaymentMethod(
    for challenges: [Challenge],
    from methods: [any PaymentMethodClient]
) -> (method: any PaymentMethodClient, challenge: Challenge)? {
    for challenge in challenges {
        if let method = methods.first(where: { $0.supports(challenge) }) {
            return (method, challenge)
        }
    }
    return nil
}
