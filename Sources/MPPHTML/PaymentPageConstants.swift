/// The DOM ids, CSS class names, and CSS custom-property names the
/// server-rendered payment page and a browser-side payment-method script agree
/// on.
///
/// These identifiers are the cross-implementation contract: they match the
/// `mppx` peer's HTML feature verbatim (`__MPPX_DATA__`, `root`, `mppx-*`
/// classes, `--mppx-*` vars) so a method script written against either
/// implementation interoperates with a page rendered by the other. They are not
/// invented here; changing them would silently break that interop.
enum PaymentPageIDs {
    /// The `<script type="application/json">` tag holding the per-challenge data map.
    static let data = "__MPPX_DATA__"
    /// The element where a single method's payment form mounts (`root-{i}` per panel
    /// on a multi-method page).
    static let root = "root"
}

/// Query parameters the page and a browser-side script agree on.
enum PaymentPageParams {
    /// Carries the selected tab slug on a multi-method page, so the choice survives a reload.
    static let tab = "__mppx_tab"
}

/// `data-*` attributes the multi-method page and the tab script agree on.
enum PaymentPageAttrs {
    /// Binds a method's injected `<script>` to its challenge on a multi-method page,
    /// so the method script can find its own entry in the data map.
    static let challengeID = "data-mppx-challenge-id"
    /// The number of challenges still to be processed, on the data `<script>`.
    static let remaining = "data-remaining"
}

enum PaymentPageClassNames {
    static let error = "mppx-error"
    static let header = "mppx-header"
    static let logo = "mppx-logo"
    static let summary = "mppx-summary"
    static let summaryAmount = "mppx-summary-amount"
    static let summaryDescription = "mppx-summary-description"
    static let summaryExpires = "mppx-summary-expires"
    static let tab = "mppx-tab"
    static let tabList = "mppx-tablist"
    static let tabPanel = "mppx-tabpanel"
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
///
/// This guards the HTML breakout (script injection), not CSS-rule injection: a
/// theme value such as `} * { background: url(...) }` could still inject CSS
/// (e.g. an exfiltrating `url()`). That is acceptable under the contract that
/// theme values are host-supplied (server-controlled), never end-user input; a
/// multi-tenant host accepting tenant themes would need a CSS value allowlist on
/// top. Legitimate theme values (colors, fonts, sizes) contain none of these.
func sanitizeCSS(_ value: String) -> String {
    value
        .replacingOccurrences(of: "<", with: "\\00003c ")
        .replacingOccurrences(of: ">", with: "\\00003e ")
}
