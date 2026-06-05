import Foundation
import MPPCore
import Testing
@testable import MPPHTML

@Suite("PaymentPage escaping")
struct PaymentPageEscapingTests {
    @Test("sanitizeHTML escapes the five HTML metacharacters, ampersand first")
    func sanitizeMetacharacters() {
        #expect(sanitizeHTML("<b>&\"'</b>") == "&lt;b&gt;&amp;&quot;&#39;&lt;/b&gt;")
        // `&` must be escaped first, or the entities it introduces are double-escaped.
        #expect(sanitizeHTML("&amp;") == "&amp;amp;")
    }

    @Test("a malicious amount is sanitized in the visible HTML")
    func amountSanitized() throws {
        let challenge = try makeChallenge()
        let html = PaymentPage.render(
            challenge: challenge,
            formattedAmount: "<img src=x onerror=alert(1)>",
            method: PaymentMethodContent(content: "")
        )
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        #expect(!html.contains("<img src=x onerror=alert(1)>"))
    }

    @Test("a malicious description is sanitized in the summary row")
    func descriptionSanitized() throws {
        let challenge = try makeChallenge(description: "</p><script>steal()</script>")
        let html = PaymentPage.render(
            challenge: challenge, formattedAmount: "1.00", method: PaymentMethodContent(content: "")
        )
        #expect(html.contains("&lt;/p&gt;&lt;script&gt;steal()&lt;/script&gt;"))
        #expect(!html.contains("<script>steal()</script>"))
    }

    @Test("a < in embedded JSON data is escaped so it cannot close the host <script>")
    func jsonScriptBreakoutPrevented() throws {
        // A method config value containing a literal `</script>`: in the JSON data block this must
        // become `<...` so the browser does not see a closing script tag mid-JSON.
        let challenge = try makeChallenge()
        let html = PaymentPage.render(
            challenge: challenge,
            formattedAmount: "1.00",
            method: PaymentMethodContent(
                content: "", config: .object(["note": .string("</script><script>x</script>")])
            )
        )
        #expect(html.contains("\\u003c/script>\\u003cscript>x\\u003c/script>"))
        // The raw, unescaped breakout sequence must never reach the page.
        #expect(!html.contains("</script><script>x</script>"))
    }

    @Test("a malicious theme value cannot break out of the <style> element")
    func cssStyleBreakoutPrevented() throws {
        // A host theme value containing `</style><script>`: the HTML parser ends a style element
        // on the literal `</style>`, so the `<` must be CSS-escaped before it reaches the page.
        let challenge = try makeChallenge()
        let html = PaymentPage.render(
            challenge: challenge,
            formattedAmount: "1.00",
            method: PaymentMethodContent(content: ""),
            config: PaymentPageConfig(theme: PaymentPageTheme(
                fontFamily: "x; } </style><script>alert(1)</script> .y { color"
            ))
        )
        // The injected breakout sequence must never appear unescaped (the legitimate `</style>`
        // closers remain, but the `</style><script>` injection specifically must not).
        #expect(!html.contains("</style><script>"))
        // The `<` was replaced by its CSS numeric escape.
        #expect(html.contains("\\00003c /style"))
    }

    @Test("a malicious color value is also CSS-escaped")
    func cssColorBreakoutPrevented() throws {
        let challenge = try makeChallenge()
        let html = PaymentPage.render(
            challenge: challenge,
            formattedAmount: "1.00",
            method: PaymentMethodContent(content: ""),
            config: PaymentPageConfig(theme: PaymentPageTheme(accent: "</style><script>x</script>"))
        )
        #expect(!html.contains("</style><script>x"))
    }

    @Test("text labels are raw in the embedded data but escaped in the HTML")
    func textRawInDataEscapedInHTML() throws {
        let challenge = try makeChallenge()
        let html = PaymentPage.render(
            challenge: challenge,
            formattedAmount: "1.00",
            method: PaymentMethodContent(content: ""),
            config: PaymentPageConfig(
                text: PaymentPageText(pay: "Buy & Read", paymentRequired: "Pay & Go")
            )
        )
        // HTML: escaped at the interpolation point.
        #expect(html.contains("<span>Pay &amp; Go</span>"))
        #expect(html.contains("<title>Pay &amp; Go</title>"))
        // JSON data block: raw, so a method script reads the true label, not `Pay &amp; Go`.
        #expect(html.contains("\"paymentRequired\":\"Pay & Go\""))
        #expect(html.contains("\"pay\":\"Buy & Read\""))
    }

    @Test("the embedded data block is deterministic across renders")
    func deterministic() throws {
        let challenge = try makeChallenge(description: "Hello & welcome")
        let method = PaymentMethodContent(content: "<script>go()</script>")
        let first = PaymentPage.render(challenge: challenge, formattedAmount: "9", method: method)
        let second = PaymentPage.render(challenge: challenge, formattedAmount: "9", method: method)
        #expect(first == second)
    }
}
