import Foundation
import MPPCore
import MPPDiscovery
import Testing

// §4.4.1 (audit decision: keep lenient + pin it): the x-payment-info offer schema marks
// intent/method/amount REQUIRED, but the advisory discovery path decodes them leniently -- matching
// the mppx peer (a shared divergence). The authoritative contract is the runtime 402, not this
// hint, so an offer missing a "REQUIRED" field parses rather than failing the whole document.
@Suite("PaymentOffer field leniency (§4.4.1)")
struct PaymentOfferLeniencyTests {
    @Test("an offer missing intent/method/amount still parses, with nil fields")
    func missingRequiredFieldsParse() throws {
        // Carries only a description -- none of the spec-REQUIRED intent/method/amount.
        let offer = try JSONDecoder().decode(
            PaymentOffer.self, from: Data(#"{"description": "Premium article"}"#.utf8)
        )
        #expect(offer.intent == nil)
        #expect(offer.method == nil)
        #expect(offer.amount == nil)
        #expect(offer.description == "Premium article")
    }

    @Test("an empty offer object parses to an all-nil offer")
    func emptyOfferParses() throws {
        let offer = try JSONDecoder().decode(PaymentOffer.self, from: Data("{}".utf8))
        #expect(offer.intent == nil && offer.method == nil && offer.amount == nil)
    }

    @Test("a fully-specified offer still parses, for contrast")
    func fullOfferParses() throws {
        let json = #"{"amount": "1000", "currency": "USD", "intent": "charge", "method": "tempo"}"#
        let offer = try JSONDecoder().decode(PaymentOffer.self, from: Data(json.utf8))
        let amount = try Amount("1000")
        #expect(offer.intent == "charge")
        #expect(offer.method == "tempo")
        #expect(offer.amount == .fixed(amount))
    }
}
