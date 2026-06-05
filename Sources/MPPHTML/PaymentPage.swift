import Foundation
import MPPCore

/// A payment method's contribution to a payment page: the `<script>` fragment
/// that mounts and drives its form, an optional method-specific `config` object
/// embedded in the page data, and an optional display `label` (defaulting to the
/// challenge's method name).
public struct PaymentMethodContent: Sendable {
    /// The method's HTML fragment, injected verbatim after the page data block.
    /// Typically a `<script>` that reads the embedded data and renders into
    /// `#root`. This is a TRUSTED, raw HTML inclusion: unlike the text and theme
    /// values the renderer sanitizes, `content` is emitted without escaping, so
    /// the host is responsible for ensuring it is safe (a server-controlled
    /// template, never an untrusted/end-user string).
    public var content: String
    /// Arbitrary method-specific configuration, embedded in the page data block
    /// for the method script to read.
    public var config: JSONValue
    /// Display label for this method. Defaults to the challenge's method name.
    public var label: String?

    /// Creates a method's page contribution from its HTML fragment, with an
    /// optional embedded config object and display label.
    public init(content: String, config: JSONValue = .object([:]), label: String? = nil) {
        self.content = content
        self.config = config
        self.label = label
    }
}

/// One method on a payment page: a challenge, its display amount, and the
/// method's HTML contribution. A page with several entries renders a tab per
/// entry; with one, a single form.
public struct PaymentPageEntry: Sendable {
    public let challenge: Challenge
    public let formattedAmount: String
    public let method: PaymentMethodContent

    public init(challenge: Challenge, formattedAmount: String, method: PaymentMethodContent) {
        self.challenge = challenge
        self.formattedAmount = formattedAmount
        self.method = method
    }
}

/// Page-level customization: the labels (``PaymentPageText``) and the visual
/// theme (``PaymentPageTheme``). Both default to a neutral light/dark scheme.
public struct PaymentPageConfig: Sendable {
    /// The page labels.
    public var text: PaymentPageText
    /// The page visual theme.
    public var theme: PaymentPageTheme

    /// Creates a page configuration from optional text and theme overrides.
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
/// data block plus each method's own `<script>` so the method can drive the form
/// client-side. With several methods it renders an accessible tab per method.
public enum PaymentPage {
    /// Renders the page for one challenge and one payment method.
    ///
    /// - Parameters:
    ///   - challenge: The minted challenge; its `realm`, `description`, and
    ///     `expires` drive the page, and its `id` keys the embedded data.
    ///   - formattedAmount: The human-readable amount (e.g. `1.50 USDC`); the
    ///     caller formats it, the renderer sanitizes it.
    ///   - method: The payment method's HTML contribution.
    ///   - config: Page text and theme overrides.
    ///   - pageScript: An optional raw `<script>` emitted once before the method
    ///     content (e.g. a credential-submission bootstrap).
    /// - Returns: a complete HTML document.
    public static func render(
        challenge: Challenge,
        formattedAmount: String,
        method: PaymentMethodContent,
        config: PaymentPageConfig = PaymentPageConfig(),
        pageScript: String? = nil
    ) -> String {
        let entry = PaymentPageEntry(
            challenge: challenge, formattedAmount: formattedAmount, method: method
        )
        return render(entries: [entry], config: config, pageScript: pageScript)
    }

    /// Renders the page for one or more methods. A single entry renders one form;
    /// several render a tab per entry, the first selected, with the summary
    /// (amount/description/expiry) switching to the active tab client-side.
    public static func render(
        entries: [PaymentPageEntry],
        config: PaymentPageConfig = PaymentPageConfig(),
        pageScript: String? = nil
    ) -> String {
        precondition(!entries.isEmpty, "A payment page needs at least one entry")
        let theme = config.theme.resolved()
        let text = config.text.resolved()
        let hasTabs = entries.count > 1
        let first = entries[0]
        let dataJSON = encodeData(pageData(entries, hasTabs: hasTabs, text: text, theme: theme))
        let remaining = hasTabs ? " \(PaymentPageAttrs.remaining)=\"\(entries.count)\"" : ""
        return """
        <!doctype html>
        <html lang="en">
          <head>
            \(headTags(theme, text: text, realm: first.challenge.realm, hasTabs: hasTabs))
          </head>
          <body>
            <main>
              <header class="\(PaymentPageClassNames.header)">
                \(PaymentPageStyle.logo(theme))
                <span>\(sanitizeHTML(text.paymentRequired))</span>
              </header>
              \(summarySection(first, text: text))
              \(tabList(entries, text: text, hasTabs: hasTabs))
              \(panels(entries, hasTabs: hasTabs))
              <script id="\(PaymentPageIDs.data)" type="application/json"\(remaining)>
                \(dataJSON)
              </script>
              \(pageScript ?? "")
              \(contentScripts(entries, hasTabs: hasTabs))
              \(hasTabs ? PaymentPageTabs.script : "")
            </main>
          </body>
        </html>
        """
    }

    /// The `<head>` contents: metadata, the resolved title, the preflight,
    /// favicon, font, and themed style blocks, plus the tab style on a
    /// multi-method page.
    private static func headTags(
        _ theme: ResolvedTheme, text: ResolvedText, realm: String, hasTabs: Bool
    ) -> String {
        """
        <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <meta name="robots" content="noindex" />
            <meta name="color-scheme" content="\(sanitizeHTML(theme.colorScheme))" />
            <title>\(sanitizeHTML(text.title))</title>
            \(PaymentPagePreflight.style)
            \(PaymentPageStyle.favicon(theme, realm: realm))
            \(PaymentPageStyle.font(theme))
            \(PaymentPageStyle.style(theme))
            \(hasTabs ? PaymentPageTabs.style : "")
        """
    }

    /// The payment summary for the (first) entry: its amount, and the optional
    /// description and expiry rows. On a multi-method page the tab script swaps
    /// these to the active tab.
    private static func summarySection(_ entry: PaymentPageEntry, text: ResolvedText) -> String {
        let amount = "<h1 class=\"\(PaymentPageClassNames.summaryAmount)\">"
            + "\(sanitizeHTML(entry.formattedAmount))</h1>"
        return "<section class=\"\(PaymentPageClassNames.summary)\" aria-label=\"Payment summary\">"
            + "\(amount)\(summaryDescription(entry.challenge))"
            + "\(summaryExpires(entry.challenge, text: text))</section>"
    }

    /// The optional `<p>` showing the challenge description, sanitized; empty
    /// when the challenge carries none.
    private static func summaryDescription(_ challenge: Challenge) -> String {
        guard let description = challenge.description else { return "" }
        return "<p class=\"\(PaymentPageClassNames.summaryDescription)\">"
            + "\(sanitizeHTML(description))</p>"
    }

    /// The optional `<p>` showing the expiry as a `<time>` element; empty when
    /// the challenge has no deadline.
    private static func summaryExpires(_ challenge: Challenge, text: ResolvedText) -> String {
        guard let expires = challenge.expires else { return "" }
        let (datetime, display) = expiryParts(expires)
        return "<p class=\"\(PaymentPageClassNames.summaryExpires)\">\(sanitizeHTML(text.expires)) "
            + "<time datetime=\"\(datetime)\">\(display)</time></p>"
    }

    /// The normalized UTC `datetime` and the deterministic display string for an
    /// expiry. `datetime` is ISO 8601; the display is a fixed `en_US_POSIX`/UTC
    /// rendering (the peer uses the server locale, which a server-rendered page
    /// cannot make reproducible). Built locally: the formatters are non-Sendable
    /// under Swift 6 strict concurrency, so they cannot be shared statics.
    static func expiryParts(_ expires: Expires) -> (datetime: String, display: String) {
        let datetime = ISO8601DateFormatter().string(from: expires.date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy, h:mm:ss a 'UTC'"
        return (datetime, formatter.string(from: expires.date))
    }

    /// The per-challenge data map. Each entry's form mounts at `root` (single
    /// method) or `root-{i}` (one per tab panel).
    private static func pageData(
        _ entries: [PaymentPageEntry], hasTabs: Bool, text: ResolvedText, theme: ResolvedTheme
    ) -> [String: PageData] {
        var map: [String: PageData] = [:]
        for (index, entry) in entries.enumerated() {
            let rootId = hasTabs ? "\(PaymentPageIDs.root)-\(index)" : PaymentPageIDs.root
            map[entry.challenge.id] = PageData(
                label: entry.method.label ?? entry.challenge.method.rawValue,
                rootId: rootId,
                formattedAmount: entry.formattedAmount,
                config: entry.method.config,
                challenge: entry.challenge,
                text: text,
                theme: theme
            )
        }
        return map
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
