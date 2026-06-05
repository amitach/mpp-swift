/// The DOM ids, CSS class names, and CSS custom-property names the
/// server-rendered payment page and a browser-side payment-method script agree
/// on.
///
/// These identifiers are the cross-implementation contract: they match the
/// `mppx` peer's HTML feature verbatim (`__MPPX_DATA__`, `root`, `mppx-*`
/// classes, `--mppx-*` vars) so a method script written against either
/// implementation interoperates with a page rendered by the other. They are not
/// invented here; changing them would silently break that interop. (The
/// service-worker query params and the multi-method tab/attribute identifiers
/// land with the features that use them.)
enum PaymentPageIDs {
    /// The `<script type="application/json">` tag holding the per-challenge data map.
    static let data = "__MPPX_DATA__"
    /// The element where a single method's payment form mounts.
    static let root = "root"
}

enum PaymentPageClassNames {
    static let error = "mppx-error"
    static let header = "mppx-header"
    static let logo = "mppx-logo"
    static let summary = "mppx-summary"
    static let summaryAmount = "mppx-summary-amount"
    static let summaryDescription = "mppx-summary-description"
    static let summaryExpires = "mppx-summary-expires"
}

/// The `--mppx-*` CSS custom-property names, in the order they are emitted, so
/// the style block and the resolved-theme data map name colors identically.
enum PaymentPageVars {
    static let accent = "--mppx-accent"
    static let background = "--mppx-background"
    static let border = "--mppx-border"
    static let foreground = "--mppx-foreground"
    static let muted = "--mppx-muted"
    static let negative = "--mppx-negative"
    static let positive = "--mppx-positive"
    static let surface = "--mppx-surface"
    static let fontFamily = "--mppx-font-family"
    static let fontSizeBase = "--mppx-font-size-base"
    static let radius = "--mppx-radius"
    static let spacingUnit = "--mppx-spacing-unit"
}

/// Escapes a string for safe interpolation into HTML text or a double-quoted
/// attribute value, matching the peer's `sanitize` byte-for-byte: `&` first (so
/// the entities introduced below are not re-escaped), then `<`, `>`, `"`, `'`.
/// Every page-rendered value derived from a challenge or caller config passes
/// through this; a value embedded in the JSON data block is additionally guarded
/// by ``PaymentPageJSON``.
func sanitizeHTML(_ value: String) -> String {
    var result = value
    result = result.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    result = result.replacingOccurrences(of: "\"", with: "&quot;")
    result = result.replacingOccurrences(of: "'", with: "&#39;")
    return result
}

/// Neutralizes the HTML-parser breakout vector in a value interpolated into a
/// `<style>` element. The HTML parser ends a style element at the literal
/// `</style>` substring regardless of CSS context, so any `<` (and, for
/// symmetry, `>`) is replaced with its CSS numeric escape, which the CSS parser
/// reads back as the original character while the HTML parser never sees a `<`.
/// A defense-in-depth guard for host-supplied theme values (colors, fonts,
/// sizes), which legitimately never contain these characters.
func sanitizeCSS(_ value: String) -> String {
    value
        .replacingOccurrences(of: "<", with: "\\00003c ")
        .replacingOccurrences(of: ">", with: "\\00003e ")
}
