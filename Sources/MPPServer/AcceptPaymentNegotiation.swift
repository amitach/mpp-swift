import MPPCore

/// The offers to advertise to a client that sent `accept` (its `Accept-Payment` preferences),
/// per `draft-httpauth-payment-00` §7.4. Each offer's weight is the `q` of its MOST-SPECIFIC
/// matching range (specificity before `q`, matching the mppx peer); an offer the client opted out
/// of (no `q>0` match) is dropped, and the rest are ordered most-preferred first (descending `q`,
/// stable on ties).
///
/// An empty `accept` (an absent or unparseable `Accept-Payment` header) means "accept any", so the
/// offers are returned unchanged. If the preference excludes every offer, all offers are advertised
/// anyway: a `402` must still tell the client what the resource accepts, even a method it cannot
/// currently pay with.
func negotiatedOffers(_ offers: [MethodOffer], for accept: [PaymentRange]) -> [MethodOffer] {
    guard !accept.isEmpty else { return offers }
    let ranked: [RankedOffer] = offers.enumerated().compactMap { entry in
        let (index, offer) = entry
        // The most-specific matching range decides this offer's weight (specificity before q);
        // among equally-specific matches the higher q wins (RFC 9110 §12.5.1).
        let best = accept
            .filter { $0.matches(method: offer.binding.method, intent: offer.binding.intent) }
            .max { lhs, rhs in
                specificity(lhs) != specificity(rhs)
                    ? specificity(lhs) < specificity(rhs)
                    : lhs.quality < rhs.quality
            }
        guard let best, best.quality > 0 else { return nil }
        return RankedOffer(offer: offer, quality: best.quality, index: index)
    }
    guard !ranked.isEmpty else { return offers }
    return ranked
        .sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.index < $1.index }
        .map(\.offer)
}

/// An offer paired with its negotiated weight and original position (for a stable sort).
private struct RankedOffer {
    let offer: MethodOffer
    let quality: Double
    let index: Int
}

/// The number of non-wildcard tokens in a range (`2` = fully specific, `0` = `*/*`).
private func specificity(_ range: PaymentRange) -> Int {
    var count = 0
    if case .value = range.method { count += 1 }
    if case .value = range.intent { count += 1 }
    return count
}
