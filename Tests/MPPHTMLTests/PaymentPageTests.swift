import Foundation
import MPPCore
import Testing
@testable import MPPHTML

@Suite("PaymentPage structure")
struct PaymentPageStructureTests {
    private func render(
        description: String? = nil,
        method: PaymentMethodContent = PaymentMethodContent(content: "<script>pay()</script>"),
        config: PaymentPageConfig = PaymentPageConfig()
    ) throws -> String {
        let challenge = try makeChallenge(description: description)
        return PaymentPage.render(
            challenge: challenge, formattedAmount: "1.50 USDC", method: method, config: config
        )
    }

    @Test("renders a complete HTML document with the amount, root mount, and method content")
    func completeDocument() throws {
        let html = try render()
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<html lang=\"en\">"))
        #expect(html.contains("<meta name=\"robots\" content=\"noindex\" />"))
        #expect(html.contains("<h1 class=\"mppx-summary-amount\">1.50 USDC</h1>"))
        #expect(html.contains("<div id=\"root\" aria-label=\"Payment form\"></div>"))
        #expect(html.contains("<script id=\"__MPPX_DATA__\" type=\"application/json\">"))
        #expect(html.contains("<script>pay()</script>"))
        #expect(html.hasSuffix("</html>"))
    }

    @Test("embeds the per-challenge data keyed by challenge id, with label and amount")
    func embedsData() throws {
        let html = try render()
        #expect(html.contains("\"chal-123\""))
        #expect(html.contains("\"label\":\"tempo\""))
        #expect(html.contains("\"formattedAmount\":\"1.50 USDC\""))
        #expect(html.contains("\"rootId\":\"root\""))
    }

    @Test("a method label override replaces the default method name")
    func labelOverride() throws {
        let html = try render(
            method: PaymentMethodContent(content: "<script></script>", label: "Tempo Pay")
        )
        #expect(html.contains("\"label\":\"Tempo Pay\""))
    }

    @Test("the description row appears only when the challenge carries one")
    func descriptionRow() throws {
        // The class always appears in the stylesheet; assert on the rendered element.
        #expect(try !render().contains("<p class=\"mppx-summary-description\">"))
        let withDesc = try render(description: "Premium article")
        #expect(withDesc.contains("<p class=\"mppx-summary-description\">Premium article</p>"))
    }
}

@Suite("PaymentPage expiry")
struct PaymentPageExpiryTests {
    @Test("an expiring challenge renders a <time> with the normalized UTC instant")
    func expiryRow() throws {
        let challenge = try makeChallenge()
        let html = PaymentPage.render(
            challenge: challenge,
            formattedAmount: "1.00",
            method: PaymentMethodContent(content: "")
        )
        #expect(html.contains("<time datetime=\"2026-01-02T00:00:00Z\">"))
        #expect(html.contains("Expires at"))
        #expect(html.contains("Jan 2, 2026"))
        #expect(html.contains("UTC</time>"))
    }

    @Test("a challenge with no expiry renders no expiry row")
    func noExpiry() throws {
        let challenge = try makeChallenge(expires: nil)
        let html = PaymentPage.render(
            challenge: challenge,
            formattedAmount: "1.00",
            method: PaymentMethodContent(content: "")
        )
        #expect(!html.contains("<p class=\"mppx-summary-expires\">"))
        #expect(!html.contains("<time"))
    }
}

@Suite("PaymentPage text")
struct PaymentPageTextTests {
    private func render(_ text: PaymentPageText) throws -> String {
        try PaymentPage.render(
            challenge: makeChallenge(),
            formattedAmount: "1.00",
            method: PaymentMethodContent(content: ""),
            config: PaymentPageConfig(text: text)
        )
    }

    @Test("default labels: Payment Required badge and title")
    func defaults() throws {
        let html = try render(PaymentPageText())
        #expect(html.contains("<title>Payment Required</title>"))
        #expect(html.contains("<span>Payment Required</span>"))
    }

    @Test("an explicit title is used verbatim")
    func explicitTitle() throws {
        let html = try render(PaymentPageText(title: "Unlock"))
        #expect(html.contains("<title>Unlock</title>"))
        #expect(html.contains("<span>Payment Required</span>"))
    }

    @Test("an omitted title falls back to the (possibly overridden) badge label")
    func titleFallsBackToBadge() throws {
        let html = try render(PaymentPageText(paymentRequired: "Members Only"))
        #expect(html.contains("<title>Members Only</title>"))
        #expect(html.contains("<span>Members Only</span>"))
    }

    @Test("an empty-string override is treated as absent (uses the default)")
    func emptyOverrideUsesDefault() throws {
        let html = try render(PaymentPageText(paymentRequired: ""))
        #expect(html.contains("<span>Payment Required</span>"))
    }
}

@Suite("PaymentPage theme")
struct PaymentPageThemeTests {
    private func render(
        _ theme: PaymentPageTheme, realm: String = "https://api.example.com"
    ) throws -> String {
        try PaymentPage.render(
            challenge: makeChallenge(realm: realm),
            formattedAmount: "1.00",
            method: PaymentMethodContent(content: ""),
            config: PaymentPageConfig(theme: theme)
        )
    }

    // The accent custom property is defined once per :root block. The default scheme defines it
    // twice (light root + dark media override); a pinned scheme defines it exactly once. (The
    // string also appears in the logo media rules and the embedded data, so assertions target the
    // `--mppx-accent: ` definition specifically.)
    @Test("the default theme emits light root vars and a dark-scheme media override")
    func defaultLightDark() throws {
        let html = try render(PaymentPageTheme())
        #expect(html.contains("color-scheme: light dark;"))
        #expect(html.contains("--mppx-accent: #171717;")) // light root
        #expect(html.contains("--mppx-accent: #ededed;")) // dark override
        #expect(occurrences(of: "--mppx-accent: ", in: html) == 2)
    }

    @Test("a pinned dark scheme puts the dark value in :root and emits no root override")
    func pinnedDark() throws {
        let html = try render(PaymentPageTheme(colorScheme: .dark))
        #expect(html.contains("color-scheme: dark;"))
        #expect(html.contains("--mppx-accent: #ededed;"))
        #expect(!html.contains("--mppx-accent: #171717;"))
        #expect(occurrences(of: "--mppx-accent: ", in: html) == 1)
    }

    @Test("a pinned light scheme emits only the light value and no root override")
    func pinnedLight() throws {
        let html = try render(PaymentPageTheme(colorScheme: .light))
        #expect(html.contains("color-scheme: light;"))
        #expect(html.contains("--mppx-accent: #171717;"))
        #expect(!html.contains("--mppx-accent: #ededed;"))
        #expect(occurrences(of: "--mppx-accent: ", in: html) == 1)
    }

    @Test("a single-value color override applies to both schemes")
    func customColorBoth() throws {
        let html = try render(PaymentPageTheme(accent: "#0099ff"))
        #expect(html.contains("--mppx-accent: #0099ff;"))
        #expect(html.contains("\"accent\":\"#0099ff\"")) // embedded data carries the bare string
    }

    @Test("a per-scheme color override emits distinct light and dark values")
    func customColorPair() throws {
        let html = try render(PaymentPageTheme(accent: .pair(light: "#111111", dark: "#eeeeee")))
        #expect(html.contains("--mppx-accent: #111111;"))
        #expect(html.contains("--mppx-accent: #eeeeee;"))
        #expect(html.contains("\"accent\":[\"#111111\",\"#eeeeee\"]")) // embedded as a pair
    }

    @Test("a logo and font URL inject the corresponding head tags")
    func logoAndFont() throws {
        let html = try render(PaymentPageTheme(
            fontURL: "https://fonts.example/x.css", logo: "https://cdn.example/l.png"
        ))
        let img = "<img alt=\"\" class=\"mppx-logo\" src=\"https://cdn.example/l.png\" />"
        let stylesheet = "<link rel=\"stylesheet\" href=\"https://fonts.example/x.css\" />"
        let preconnect = "<link rel=\"preconnect\" href=\"https://fonts.example\" crossorigin />"
        #expect(html.contains(img))
        #expect(html.contains(stylesheet))
        #expect(html.contains(preconnect))
    }

    @Test("with no favicon the realm host's favicon is used as a fallback")
    func faviconFallback() throws {
        let html = try render(PaymentPageTheme())
        let fallback = "https://www.google.com/s2/favicons?domain=api.example.com&amp;sz=64"
        #expect(html.contains(fallback))
    }
}
