import Foundation
import MPPCore
import Testing
@testable import MPPDiscovery

@Suite("MPPDiscovery")
struct DiscoveryTests {
    private func decode(_ json: String) throws -> DiscoveryDocument {
        try JSONDecoder().decode(DiscoveryDocument.self, from: Data(json.utf8))
    }

    @Test("parses OpenAPI 3.0 and 3.1; rejects other majors")
    func versionAcceptance() throws {
        for version in ["3.0.0", "3.0.3", "3.1.0", "3.1"] {
            let doc =
                try decode(
                    #"{"openapi":"\#(version)","info":{"title":"x","version":"1"},"paths":{}}"#
                )
            #expect(doc.openapi == version)
        }
        #expect(throws: (any Error).self) {
            try decode(#"{"openapi":"2.0","info":{"title":"x","version":"1"},"paths":{}}"#)
        }
    }

    @Test("emit always produces OpenAPI 3.1.0 regardless of parsed version")
    func emitsThreeOne() throws {
        let doc = try decode(#"{"openapi":"3.0.3","info":{"title":"x","version":"1"},"paths":{}}"#)
        let data = try JSONEncoder().encode(doc)
        let reparsed = try JSONDecoder().decode(DiscoveryDocument.self, from: data)
        #expect(reparsed.openapi == "3.1.0")
    }

    @Test("amount: null means dynamic; a value is fixed; absent is nil")
    func amountForms() throws {
        let doc = try decode(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/dyn":{"get":{"x-payment-info":{"amount":null,"currency":"USD"}}},
          "/fix":{"post":{"x-payment-info":{"amount":"1000000","currency":"USD"}}},
          "/none":{"get":{"x-payment-info":{"currency":"USD"}}}
        }}
        """#)
        #expect(doc.paths["/dyn"]?[.get]?.paymentInfo?.offers.first?.amount == .dynamic)
        let fixed = try #require(doc.paths["/fix"]?[.post]?.paymentInfo?.offers.first?.amount)
        #expect(try fixed == .fixed(Amount("1000000")))
        #expect(doc.paths["/none"]?[.get]?.paymentInfo?.offers.first?.amount == nil)
    }

    @Test("flat x-payment-info normalizes to a single offer; offers[] is preserved")
    func flatVsOffers() throws {
        let flat = try decode(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/a":{"get":{"x-payment-info":{"amount":"5","currency":"USD","intent":"charge"}}}}}
        """#)
        let flatOffer = try #require(flat.paths["/a"]?[.get]?.paymentInfo?.offers)
        #expect(flatOffer.count == 1)
        #expect(flatOffer.first?.intent == "charge")

        let multi = try decode(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/b":{"get":{"x-payment-info":{"offers":[{"amount":"5"},{"amount":null}]}}}}}
        """#)
        #expect(multi.paths["/b"]?[.get]?.paymentInfo?.offers.count == 2)
    }

    @Test("emit -> parse round-trips the discovery content (3.0 input)")
    func roundTrip() throws {
        let offers = try [
            PaymentOffer(amount: .fixed(Amount("250000")), currency: "USD"),
            PaymentOffer(amount: .dynamic, currency: "USDC"),
        ]
        let operation = DiscoveryOperation(paymentInfo: .init(offers: offers), summary: "Charge")
        let original = DiscoveryDocument(
            info: .init(title: "Pay API", version: "2.0.0"),
            paths: ["/charge": [.post: operation]],
            serviceInfo: .init(categories: ["payments"], docs: .init(homepage: "https://x.example"))
        )
        let data = try JSONEncoder().encode(original)
        let parsed = try JSONDecoder().decode(DiscoveryDocument.self, from: data)
        #expect(parsed.info == original.info)
        #expect(parsed.paths == original.paths)
        #expect(parsed.serviceInfo == original.serviceInfo)
    }

    @Test("validator flags a non-integer (float) amount with a path")
    func validatorFlagsFloat() {
        let json = Data(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/p":{"get":{"x-payment-info":{"amount":"1.5"}}}}}
        """#.utf8)
        let errors = DiscoveryValidator.validate(json)
        #expect(errors.count == 1)
        #expect(errors.first?.severity == .error)
        #expect(errors.first?.path.contains("amount") == true)
    }

    @Test("validator passes a well-formed document")
    func validatorPasses() {
        let json = Data(#"""
        {"openapi":"3.0.0","info":{"title":"x","version":"1"},"paths":{
          "/p":{"get":{"x-payment-info":{"amount":"100","currency":"USD"}}}},
          "x-service-info":{"categories":["ai"],"docs":{"llms":"/llms.txt"}}}
        """#.utf8)
        #expect(DiscoveryValidator.validate(json).isEmpty)
    }

    @Test("validator rejects mixing offers with flat fields")
    func validatorRejectsMixed() {
        let json = Data(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/p":{"get":{"x-payment-info":{"amount":"5","offers":[{"amount":"5"}]}}}}}
        """#.utf8)
        #expect(DiscoveryValidator.validate(json).isEmpty == false)
    }

    @Test("tolerates arbitrary OpenAPI content (floats, non-method keys) in ignored fields")
    func toleratesArbitraryContent() throws {
        let doc = try decode(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/p":{
            "parameters":[{"name":"q","in":"query"}],
            "get":{"x-payment-info":{"amount":"5"},
                   "responses":{"200":{"content":{"application/json":{
                     "schema":{"multipleOf":0.5}}}}}}
          }}}
        """#)
        // The float (multipleOf 0.5) and the non-method "parameters" key are ignored;
        // the payment info still parses.
        #expect(try doc.paths["/p"]?[.get]?.paymentInfo?.offers.first?
            .amount == .fixed(Amount("5")))
    }

    @Test("x-service-info parses categories and docs")
    func serviceInfo() throws {
        let doc = try decode(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{},
         "x-service-info":{"categories":["a","b"],
           "docs":{"apiReference":"/ref","homepage":"https://h","llms":"/llms.txt"}}}
        """#)
        #expect(doc.serviceInfo?.categories == ["a", "b"])
        #expect(doc.serviceInfo?.docs?.apiReference == "/ref")
        #expect(doc.serviceInfo?.docs?.llms == "/llms.txt")
    }
}
