import Foundation
import MPPCore

/// A payment method's contribution to a payment page: the `<script>` fragment
/// that mounts and drives its form, an optional method-specific `config` object
/// embedded in the page data, and an optional display `label` (defaulting to the
/// challenge's method name).
public struct PaymentMethodContent: Sendable {
    /// The method's HTML fragment, injected after the page data block. Typically
    /// a `<script>` that reads the embedded data and renders into `#root`.
    public var content: String
    /// Arbitrary method-specific configuration, embedded in the page data block
    /// for the method script to read.
    public var config: JSONValue
    /// Display label for this method. Defaults to the challenge's method name.
    public var label: String?

    public init(content: String, config: JSONValue = .object([:]), label: String? = nil) {
        self.content = content
        self.config = config
        self.label = label
    }
}

/// Page-level customization: the labels (``PaymentPageText``) and the visual
/// theme (``PaymentPageTheme``). Both default to a neutral light/dark scheme.
public struct PaymentPageConfig: Sendable {
    public var text: PaymentPageText
    public var theme: PaymentPageTheme

    public init(
        text: PaymentPageText = PaymentPageText(),
        theme: PaymentPageTheme = PaymentPageTheme()
    ) {
        self.text = text
        self.theme = theme
    }
}

/// Renders the server-side HTML payment page a browser sees when it hits a
/// paywalled endpoint with `Accept: text/html`. The page presents the amount,
/// description, and expiry from a ``Challenge``, is themeable, and embeds a JSON
/// data block plus the payment method's own `<script>` so the method can drive
/// the form client-side.
///
/// This is the single-method renderer; multi-method (tabbed) pages and the
/// browser service worker that submits the credential are layered on separately.
public enum PaymentPage {
    /// Renders the page for one challenge and one payment method.
    ///
    /// - Parameters:
    ///   - challenge: The minted challenge; its `realm`, `description`, and
    ///     `expires` drive the page, and its `id` keys the embedded data.
    ///   - formattedAmount: The human-readable amount to display (e.g.
    ///     `1.50 USDC`). The caller formats it; the renderer sanitizes it.
    ///   - method: The payment method's HTML contribution.
    ///   - config: Page text and theme overrides.
    /// - Returns: a complete HTML document.
    public static func render(
        challenge: Challenge,
        formattedAmount: String,
        method: PaymentMethodContent,
        config: PaymentPageConfig = PaymentPageConfig()
    ) -> String {
        let theme = config.theme.resolved()
        let text = config.text.resolved()
        let label = method.label ?? challenge.method.rawValue

        let data = PageData(
            label: label,
            rootId: PaymentPageIDs.root,
            formattedAmount: formattedAmount,
            config: method.config,
            challenge: challenge,
            text: text,
            theme: theme
        )
        let dataJSON = encodeData([challenge.id: data])

        return """
        <!doctype html>
        <html lang="en">
          <head>
            \(headTags(theme, text: text, realm: challenge.realm))
          </head>
          <body>
            <main>
              <header class="\(PaymentPageClassNames.header)">
                \(PaymentPageStyle.logo(theme))
                <span>\(text.paymentRequired)</span>
              </header>
              <section class="\(PaymentPageClassNames.summary)" aria-label="Payment summary">
                <h1 class="\(PaymentPageClassNames.summaryAmount)">\(sanitizeHTML(formattedAmount))\
        </h1>
                \(summaryDescription(challenge))
                \(summaryExpires(challenge, text: text))
              </section>
              <div id="\(PaymentPageIDs.root)" aria-label="Payment form"></div>
              <script id="\(PaymentPageIDs.data)" type="application/json">
                \(dataJSON)
              </script>
              \(method.content)
            </main>
          </body>
        </html>
        """
    }

    /// The `<head>` contents: metadata, the resolved title, and the preflight,
    /// favicon, font, and themed style blocks.
    private static func headTags(
        _ theme: ResolvedTheme, text: ResolvedText, realm: String
    ) -> String {
        """
        <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <meta name="robots" content="noindex" />
            <meta name="color-scheme" content="\(theme.colorScheme)" />
            <title>\(text.title)</title>
            \(PaymentPagePreflight.style)
            \(PaymentPageStyle.favicon(theme, realm: realm))
            \(PaymentPageStyle.font(theme))
            \(PaymentPageStyle.style(theme))
        """
    }

    /// The optional `<p>` showing the challenge description, sanitized; empty
    /// when the challenge carries none.
    private static func summaryDescription(_ challenge: Challenge) -> String {
        guard let description = challenge.description else { return "" }
        return "<p class=\"\(PaymentPageClassNames.summaryDescription)\">"
            + "\(sanitizeHTML(description))</p>"
    }

    /// The optional `<p>` showing the expiry as a `<time>` element; empty when
    /// the challenge has no deadline. `datetime` carries the normalized UTC
    /// instant; the visible text is a deterministic UTC rendering (the peer uses
    /// the server locale, which a server-rendered page cannot make reproducible).
    private static func summaryExpires(_ challenge: Challenge, text: ResolvedText) -> String {
        guard let expires = challenge.expires else { return "" }
        // Formatters are built locally: `ISO8601DateFormatter`/`DateFormatter` are
        // non-Sendable, so they cannot be shared statics under Swift 6 strict concurrency.
        let datetime = ISO8601DateFormatter().string(from: expires.date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy, h:mm:ss a 'UTC'"
        let display = formatter.string(from: expires.date)
        return "<p class=\"\(PaymentPageClassNames.summaryExpires)\">\(text.expires) "
            + "<time datetime=\"\(datetime)\">\(display)</time></p>"
    }

    /// JSON-encodes the per-challenge data map deterministically (sorted keys),
    /// then replaces every literal `<` with its JSON unicode escape so an
    /// embedded value can never close the host `<script>` element (a
    /// `</script>` breakout). Best-effort: the data is diagnostic; an encoding
    /// failure yields an empty object rather than failing the page.
    private static func encodeData(_ dataMap: [String: PageData]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(dataMap))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }
}

/// The per-challenge data embedded in the page's `<script type="application/json">`
/// block, keyed by challenge id. A method script reads it to render its form.
/// Field names match the peer's embedded shape.
private struct PageData: Encodable {
    let label: String
    let rootId: String
    let formattedAmount: String
    let config: JSONValue
    let challenge: Challenge
    let text: ResolvedText
    let theme: ResolvedTheme
}
