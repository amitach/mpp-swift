import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §6 — Accept-Payment = #payment-range, each
// (method-or-*)/(intent-or-*) with an optional ;q= weight (omitted=1, q=0 means
// "do not use"). Client -> server.
@Suite("AcceptPayment")
struct AcceptPaymentTests {
    @Test("parses a list of method/intent ranges with default quality")
    func parsesPlainList() throws {
        let ranges = try AcceptPayment.parse("tempo/charge, stripe/session")
        let tempo = try MethodName("tempo")
        let stripe = try MethodName("stripe")
        #expect(ranges.count == 2)
        #expect(ranges[0].method == .value(tempo))
        #expect(ranges[0].intent == .value(.charge))
        #expect(ranges[0].quality == 1)
        #expect(ranges[1].method == .value(stripe))
        #expect(ranges[1].intent == .value(.session))
    }

    @Test("parses method and intent wildcards")
    func parsesWildcards() throws {
        let ranges = try AcceptPayment.parse("tempo/*, */session")
        let tempo = try MethodName("tempo")
        #expect(ranges[0].method == .value(tempo))
        #expect(ranges[0].intent == .any)
        #expect(ranges[1].method == .any)
        #expect(ranges[1].intent == .value(.session))
    }

    @Test("parses explicit q weights including q=0")
    func parsesQuality() throws {
        let ranges = try AcceptPayment.parse("tempo/charge;q=0.5, stripe/charge;q=0")
        #expect(ranges[0].quality == 0.5)
        #expect(ranges[1].quality == 0)
    }

    @Test("q parameter name is case-insensitive")
    func qualityCaseInsensitive() throws {
        let ranges = try AcceptPayment.parse("tempo/charge;Q=0.3")
        #expect(ranges[0].quality == 0.3)
    }

    @Test("skips empty list elements (RFC 9110 # rule)")
    func skipsEmptyElements() throws {
        let ranges = try AcceptPayment.parse("tempo/charge, , ,stripe/charge")
        #expect(ranges.count == 2)
    }

    @Test("matches concrete method/intent, with wildcards covering anything")
    func matchesSemantics() throws {
        let tempo = try MethodName("tempo")
        let stripe = try MethodName("stripe")
        let solana = try MethodName("solana")

        let tempoAny = PaymentRange(method: .value(tempo), intent: .any)
        #expect(tempoAny.matches(method: tempo, intent: .charge))
        #expect(tempoAny.matches(method: tempo, intent: .session))
        #expect(!tempoAny.matches(method: stripe, intent: .charge))

        let anySession = PaymentRange(method: .any, intent: .value(.session))
        #expect(anySession.matches(method: solana, intent: .session))
        #expect(!anySession.matches(method: solana, intent: .charge))

        let exact = PaymentRange(method: .value(tempo), intent: .value(.charge))
        #expect(exact.matches(method: tempo, intent: .charge))
        #expect(!exact.matches(method: tempo, intent: .session))
    }

    @Test("formats ranges, emitting ;q= only when the weight is not 1")
    func formats() throws {
        let ranges = try [
            PaymentRange(method: .value(MethodName("tempo")), intent: .value(.charge)),
            PaymentRange(method: .value(MethodName("stripe")), intent: .any, quality: 0.5),
            PaymentRange(method: .any, intent: .value(.session), quality: 0),
        ]
        #expect(AcceptPayment.format(ranges) == "tempo/charge, stripe/*;q=0.5, */session;q=0")
    }

    @Test("round-trips parse -> format -> parse")
    func roundTrips() throws {
        let header = "tempo/charge, solana/*;q=0.6, */session;q=0.3"
        let ranges = try AcceptPayment.parse(header)
        #expect(AcceptPayment.format(ranges) == header)
    }

    @Test("rejects a token without exactly one slash")
    func rejectsMalformedToken() {
        #expect(throws: AcceptPayment.ParseError.self) {
            try AcceptPayment.parse("tempocharge")
        }
        #expect(throws: AcceptPayment.ParseError.self) {
            try AcceptPayment.parse("a/b/c")
        }
    }

    @Test("rejects an uppercase method (neither * nor valid MethodName)")
    func rejectsInvalidMethod() {
        #expect(throws: AcceptPayment.ParseError.self) {
            try AcceptPayment.parse("Tempo/charge")
        }
    }

    @Test("rejects an intent with a space")
    func rejectsInvalidIntent() {
        #expect(throws: AcceptPayment.ParseError.self) {
            try AcceptPayment.parse("tempo/bad intent")
        }
    }

    @Test(
        "rejects a q weight that is not a number in 0...1",
        arguments: ["tempo/charge;q=2", "tempo/charge;q=-0.1", "tempo/charge;q=high"]
    )
    func rejectsInvalidQuality(header: String) {
        #expect(throws: AcceptPayment.ParseError.self) {
            try AcceptPayment.parse(header)
        }
    }
}
