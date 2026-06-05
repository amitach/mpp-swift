import Foundation
import MPPCore
import Testing
@testable import MPPHTML

@Suite("PaymentPage multi-method")
struct PaymentPageMultiMethodTests {
    private func twoMethodPage() throws -> String {
        let tempo = try makeChallenge(id: "c-tempo", method: "tempo")
        let stripe = try makeChallenge(id: "c-stripe", method: "stripe")
        return PaymentPage.render(entries: [
            PaymentPageEntry(
                challenge: tempo, formattedAmount: "1.00",
                method: PaymentMethodContent(content: "<script>tempo()</script>")
            ),
            PaymentPageEntry(
                challenge: stripe, formattedAmount: "2.00",
                method: PaymentMethodContent(content: "<script>stripe()</script>")
            ),
        ])
    }

    @Test("renders a tab and a panel per method, with the data-remaining count")
    func tabsAndPanels() throws {
        let html = try twoMethodPage()
        #expect(html.contains("role=\"tablist\""))
        #expect(html.contains("id=\"mppx-tab-0\""))
        #expect(html.contains("id=\"mppx-tab-1\""))
        #expect(html.contains("id=\"mppx-panel-0\""))
        #expect(html.contains("id=\"mppx-panel-1\""))
        #expect(html.contains("id=\"root-0\""))
        #expect(html.contains("id=\"root-1\""))
        #expect(html.contains("data-remaining=\"2\""))
        // The second panel starts hidden; the first does not.
        #expect(html.contains("id=\"mppx-panel-1\" aria-labelledby=\"mppx-tab-1\" hidden>"))
    }

    @Test("each method script is bound to its challenge id, and the tab script is included")
    func contentBoundToChallenge() throws {
        let html = try twoMethodPage()
        #expect(html.contains("<script data-mppx-challenge-id=\"c-tempo\">tempo()</script>"))
        #expect(html.contains("<script data-mppx-challenge-id=\"c-stripe\">stripe()</script>"))
        // The tab-switch script and tab style are present on a multi-method page.
        #expect(html.contains("__mppx_tab"))
        #expect(html.contains(".mppx-tablist {"))
    }

    @Test("a method script with attributes is still bound to its challenge")
    func boundScriptWithAttributes() throws {
        let tempo = try makeChallenge(id: "c-tempo", method: "tempo")
        let stripe = try makeChallenge(id: "c-stripe", method: "stripe")
        let html = PaymentPage.render(entries: [
            PaymentPageEntry(
                challenge: tempo, formattedAmount: "1",
                method: PaymentMethodContent(content: "<script type=\"module\">a()</script>")
            ),
            PaymentPageEntry(
                challenge: stripe, formattedAmount: "2",
                method: PaymentMethodContent(content: "<script defer>b()</script>")
            ),
        ])
        let tempoTag = "<script data-mppx-challenge-id=\"c-tempo\" type=\"module\">a()</script>"
        #expect(html.contains(tempoTag))
        #expect(html.contains("<script data-mppx-challenge-id=\"c-stripe\" defer>b()</script>"))
    }

    @Test("the data map keys each challenge with its own root mount")
    func perEntryData() throws {
        let html = try twoMethodPage()
        #expect(html.contains("\"c-tempo\""))
        #expect(html.contains("\"c-stripe\""))
        #expect(html.contains("\"rootId\":\"root-0\""))
        #expect(html.contains("\"rootId\":\"root-1\""))
    }

    @Test("the tabs carry each method's amount and the summary shows the first")
    func tabAmountsAndSummary() throws {
        let html = try twoMethodPage()
        #expect(html.contains("data-amount=\"1.00\""))
        #expect(html.contains("data-amount=\"2.00\""))
        #expect(html.contains(">tempo</button>"))
        #expect(html.contains(">stripe</button>"))
        // The summary renders the first entry's amount.
        #expect(html.contains("<h1 class=\"mppx-summary-amount\">1.00</h1>"))
    }

    @Test("a single-entry render still produces the one-method page (no tabs)")
    func singleEntryUnchanged() throws {
        let challenge = try makeChallenge()
        let html = PaymentPage.render(
            challenge: challenge, formattedAmount: "1.00",
            method: PaymentMethodContent(content: "<script>pay()</script>")
        )
        #expect(html.contains("<div id=\"root\" aria-label=\"Payment form\"></div>"))
        #expect(!html.contains("role=\"tablist\""))
        #expect(!html.contains("data-remaining"))
        #expect(html.contains("<script>pay()</script>")) // verbatim, no challenge-id injection
    }
}
