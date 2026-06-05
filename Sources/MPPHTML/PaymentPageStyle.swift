import Foundation

/// Builds the themed `<style>` block and the favicon/font/logo head tags.
enum PaymentPageStyle {
    /// The themed style block: `:root` custom properties (with a
    /// `prefers-color-scheme: dark` override unless the scheme is pinned) plus
    /// the component CSS, every rule referencing a `--mppx-*` variable.
    static func style(_ theme: ResolvedTheme) -> String {
        let isLightOnly = theme.colorScheme == "light"
        let isDarkOnly = theme.colorScheme == "dark"
        let rootVars = colorVars(theme, dark: isDarkOnly)
        let darkMedia = (!isLightOnly && !isDarkOnly)
            ? "\n      @media (prefers-color-scheme: dark) {\n        :root {\n          "
            + colorVars(theme, dark: true) + "\n        }\n      }"
            : ""
        return """
        <style>
          :root {
            color-scheme: \(sanitizeCSS(theme.colorScheme));
            \(PaymentPageVars.fontFamily): \(sanitizeCSS(theme.fontFamily));
            \(PaymentPageVars.fontSizeBase): \(sanitizeCSS(theme.fontSizeBase));
            \(PaymentPageVars.radius): \(sanitizeCSS(theme.radius));
            \(PaymentPageVars.spacingUnit): \(sanitizeCSS(theme.spacingUnit));
            \(rootVars)
          }\(darkMedia)
        \(componentCSS)
        </style>
        """
    }

    /// The eight color custom-property lines, in the peer's emit order, taking
    /// each token's light or dark value.
    private static func colorVars(_ theme: ResolvedTheme, dark: Bool) -> String {
        let tokens: [(String, LightDarkColor)] = [
            (PaymentPageVars.accent, theme.accent),
            (PaymentPageVars.negative, theme.negative),
            (PaymentPageVars.positive, theme.positive),
            (PaymentPageVars.background, theme.background),
            (PaymentPageVars.foreground, theme.foreground),
            (PaymentPageVars.muted, theme.muted),
            (PaymentPageVars.surface, theme.surface),
            (PaymentPageVars.border, theme.border),
        ]
        return tokens
            .map { "\($0.0): \(sanitizeCSS(dark ? $0.1.dark : $0.1.light));" }
            .joined(separator: "\n        ")
    }

    /// The static component rules (everything but the themed `:root` block),
    /// each referencing a `--mppx-*` variable so a theme change needs no
    /// re-render of this block.
    private static let componentCSS = """
      *:focus-visible {
        outline-color: var(--mppx-accent);
        outline-offset: 0.15rem;
        outline-style: solid;
        outline-width: 2px;
      }
      body {
        -webkit-font-smoothing: antialiased;
        -moz-osx-font-smoothing: grayscale;
        background: var(--mppx-background);
        color: var(--mppx-foreground);
        font-family: var(--mppx-font-family);
        font-size: var(--mppx-font-size-base);
      }
      main {
        display: flex;
        flex-direction: column;
        gap: calc(var(--mppx-spacing-unit) * 8);
        margin-left: auto;
        margin-right: auto;
        max-width: clamp(300px, calc(var(--mppx-spacing-unit) * 224), 896px);
        padding: calc(var(--mppx-spacing-unit) * 12) calc(var(--mppx-spacing-unit) * 8) \
    calc(var(--mppx-spacing-unit) * 16);
      }
      .\(PaymentPageClassNames.header) {
        align-items: center;
        display: flex;
        flex-wrap: wrap;
        gap: calc(var(--mppx-spacing-unit) * 4);
        justify-content: space-between;
        span {
          background: var(--mppx-surface);
          border: 1px solid var(--mppx-border);
          border-radius: calc(var(--mppx-spacing-unit) * 50);
          font-size: 0.75rem;
          font-weight: 500;
          letter-spacing: 0.025em;
          padding: calc(var(--mppx-spacing-unit) * 1) calc(var(--mppx-spacing-unit) * 4);
        }
      }
      .\(PaymentPageClassNames.logo) {
        max-height: 1.75rem;
      }
      .\(PaymentPageClassNames.logo)--dark {
        @media (prefers-color-scheme: light) {
          display: none;
        }
      }
      .\(PaymentPageClassNames.logo)--light {
        @media (prefers-color-scheme: dark) {
          display: none;
        }
      }
      .\(PaymentPageClassNames.summary) {
        background: var(--mppx-surface);
        border: 1px solid var(--mppx-border);
        border-radius: var(--mppx-radius);
        display: flex;
        flex-direction: column;
        gap: calc(var(--mppx-spacing-unit) * 3);
        padding: calc(var(--mppx-spacing-unit) * 6) calc(var(--mppx-spacing-unit) * 6);
      }
      .\(PaymentPageClassNames.summaryAmount) {
        font-size: 2.5rem;
        font-variant-numeric: tabular-nums;
        font-weight: 700;
        line-height: 1.2;
      }
      .\(PaymentPageClassNames.summaryDescription) {
        font-size: 1.25rem;
      }
      .\(PaymentPageClassNames.summaryExpires) {
        color: var(--mppx-muted);
      }
      .\(PaymentPageClassNames.error) {
        color: var(--mppx-negative);
        font-size: 0.95rem;
        margin-top: calc(var(--mppx-spacing-unit) * -1.5);
        text-align: center;
      }
    """

    /// The favicon `<link>`(s): an explicit URL (optionally per scheme), or a
    /// fallback to the realm host's favicon via Google's S2 service. Empty when
    /// none is set and the realm is not a parseable absolute URL.
    static func favicon(_ theme: ResolvedTheme, realm: String) -> String {
        switch theme.favicon {
        case let .single(url):
            return "<link rel=\"icon\" href=\"\(sanitizeHTML(url))\" />"
        case let .pair(light, dark):
            return "<link rel=\"icon\" href=\"\(sanitizeHTML(light))\" "
                + "media=\"(prefers-color-scheme: light)\" />"
                + "<link rel=\"icon\" href=\"\(sanitizeHTML(dark))\" "
                + "media=\"(prefers-color-scheme: dark)\" />"
        case nil:
            guard let host = URL(string: realm)?.host, !host.isEmpty else { return "" }
            return "<link rel=\"icon\" "
                + "href=\"https://www.google.com/s2/favicons?domain=\(sanitizeHTML(host))&sz=64\" />"
        }
    }

    /// The font `<link>`s when a `fontURL` is set: a `preconnect` to its origin
    /// (when parseable) and the stylesheet link itself.
    static func font(_ theme: ResolvedTheme) -> String {
        guard let fontURL = theme.fontURL else { return "" }
        let stylesheet = "<link rel=\"stylesheet\" href=\"\(sanitizeHTML(fontURL))\" />"
        guard let origin = origin(of: fontURL) else { return stylesheet }
        let preconnect = "<link rel=\"preconnect\" href=\"\(sanitizeHTML(origin))\" crossorigin />"
        return preconnect + stylesheet
    }

    /// The header logo `<img>`(s): one image, or a light/dark pair toggled by the
    /// `--light`/`--dark` logo classes. Empty when no logo is set.
    static func logo(_ theme: ResolvedTheme) -> String {
        switch theme.logo {
        case let .single(url):
            return "<img alt=\"\" class=\"\(PaymentPageClassNames.logo)\" "
                + "src=\"\(sanitizeHTML(url))\" />"
        case let .pair(light, dark):
            return "<img alt=\"\" class=\"\(PaymentPageClassNames.logo) "
                + "\(PaymentPageClassNames.logo)--light\" src=\"\(sanitizeHTML(light))\" />"
                + "<img alt=\"\" class=\"\(PaymentPageClassNames.logo) "
                + "\(PaymentPageClassNames.logo)--dark\" src=\"\(sanitizeHTML(dark))\" />"
        case nil:
            return ""
        }
    }

    /// The scheme-and-authority origin of a URL (e.g. `https://fonts.example`),
    /// or `nil` if it has no scheme/host.
    private static func origin(of urlString: String) -> String? {
        guard let url = URL(string: urlString), let scheme = url.scheme, let host = url.host
        else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
