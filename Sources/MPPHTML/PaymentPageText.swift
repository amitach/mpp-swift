/// The customizable labels on a payment page. Every field is optional; a `nil`
/// or empty value falls back to the default (`Expires at`, `Pay`, `Payment
/// Required`). `title` additionally falls back to the resolved `paymentRequired`
/// when omitted, so a host that renames the badge renames the page title too.
public struct PaymentPageText: Sendable, Equatable {
    /// Prefix for the expiry line. Default `Expires at`.
    public var expires: String?
    /// Pay-button label. Default `Pay`.
    public var pay: String?
    /// Badge label. Default `Payment Required`.
    public var paymentRequired: String?
    /// Page `<title>`. Default: the resolved ``paymentRequired``.
    public var title: String?

    public init(
        expires: String? = nil,
        pay: String? = nil,
        paymentRequired: String? = nil,
        title: String? = nil
    ) {
        self.expires = expires
        self.pay = pay
        self.paymentRequired = paymentRequired
        self.title = title
    }
}

/// The fully resolved, HTML-sanitized text used by the renderer and embedded in
/// the page data block. Distinct from ``PaymentPageText`` so the renderer never
/// sees an unresolved (optional, unescaped) value.
struct ResolvedText: Equatable, Encodable {
    let expires: String
    let pay: String
    let paymentRequired: String
    let title: String
}

extension PaymentPageText {
    static let defaults = (
        expires: "Expires at",
        pay: "Pay",
        paymentRequired: "Payment Required"
    )

    /// Resolves overrides against the defaults, then sanitizes. An override is
    /// honored only when non-`nil` and non-empty (matching the peer's
    /// `mergeDefined`, which treats `''` as "use the default"). `title` becomes
    /// the override when non-empty, otherwise the resolved `paymentRequired`.
    func resolved() -> ResolvedText {
        let paymentRequired = pick(paymentRequired, Self.defaults.paymentRequired)
        let titleOverride = pick(title, "")
        let resolvedTitle = titleOverride.isEmpty ? paymentRequired : titleOverride
        return ResolvedText(
            expires: sanitizeHTML(pick(expires, Self.defaults.expires)),
            pay: sanitizeHTML(pick(pay, Self.defaults.pay)),
            paymentRequired: sanitizeHTML(paymentRequired),
            title: sanitizeHTML(resolvedTitle)
        )
    }

    /// Returns `override` when present and non-empty, otherwise `fallback`
    /// (the peer's `mergeDefined` treats an empty string as "use the default").
    private func pick(_ override: String?, _ fallback: String) -> String {
        guard let override, !override.isEmpty else { return fallback }
        return override
    }
}
