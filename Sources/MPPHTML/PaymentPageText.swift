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

    /// Creates page text from optional label overrides; omitted labels use the
    /// defaults.
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

/// The fully resolved (defaults filled, title fallback applied) text. Values are
/// raw, not HTML-escaped: the renderer sanitizes each at its HTML interpolation
/// point, and the JSON data block embeds the raw values so a method script reads
/// the true label (not `Pay &amp; Go`). This matches how every other embedded
/// field is treated, and deliberately differs from the mppx peer, which
/// pre-escapes the text in its data block.
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

    /// Resolves overrides against the defaults, leaving values raw (the renderer
    /// escapes at each HTML interpolation point). An override is honored only
    /// when non-`nil` and non-empty (matching the peer's `mergeDefined`, which
    /// treats `''` as "use the default"). `title` becomes the override when
    /// non-empty, otherwise the resolved `paymentRequired`.
    func resolved() -> ResolvedText {
        let paymentRequired = pick(paymentRequired, Self.defaults.paymentRequired)
        let titleOverride = pick(title, "")
        let resolvedTitle = titleOverride.isEmpty ? paymentRequired : titleOverride
        return ResolvedText(
            expires: pick(expires, Self.defaults.expires),
            pay: pick(pay, Self.defaults.pay),
            paymentRequired: paymentRequired,
            title: resolvedTitle
        )
    }

    /// Returns `override` when present and non-empty, otherwise `fallback`
    /// (the peer's `mergeDefined` treats an empty string as "use the default").
    private func pick(_ override: String?, _ fallback: String) -> String {
        guard let override, !override.isEmpty else { return fallback }
        return override
    }
}
