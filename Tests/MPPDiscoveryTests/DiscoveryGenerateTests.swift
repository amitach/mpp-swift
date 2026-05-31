import Foundation
import MPPCore
import Testing
@testable import MPPDiscovery

@Suite("MPPDiscovery generate + semantic validation")
struct DiscoveryGenerateTests {
    private func paymentInfo(_ json: String) throws -> PaymentInfo {
        try JSONDecoder().decode(PaymentInfo.self, from: Data(json.utf8))
    }

    // MARK: generate

    @Test("generate produces a spec-clean document that round-trips through the parser")
    func generateValidatesAndRoundTrips() throws {
        let doc = try DiscoveryGenerator.generate(
            info: .init(title: "Svc", version: "1"),
            routes: [
                DiscoveryRoute(
                    path: "/pay",
                    method: .post,
                    payment: paymentInfo(#"{"amount":"100","currency":"USD"}"#),
                    requestBody: ["description": "input"],
                    summary: "Pay for it"
                ),
            ],
            serviceInfo: ServiceInfo(categories: ["ai"])
        )
        let data = try JSONEncoder().encode(doc)

        // A generated document is spec-clean (it auto-declares the required 402).
        #expect(DiscoveryValidator.validate(data).isEmpty)

        let parsed = try JSONDecoder().decode(DiscoveryDocument.self, from: data)
        #expect(parsed.openapi == "3.1.0")
        #expect(parsed.paths["/pay"]?[.post]?.paymentInfo != nil)
        #expect(parsed.paths["/pay"]?[.post]?.summary == "Pay for it")
        #expect(parsed.serviceInfo?.categories == ["ai"])
    }

    @Test("a free route declares a 200 but no 402 and no x-payment-info")
    func generateFreeRoute() throws {
        let doc = try DiscoveryGenerator.generate(
            info: .init(title: "x", version: "1"),
            routes: [DiscoveryRoute(path: "/free", method: .get)]
        )
        let data = try JSONEncoder().encode(doc)
        #expect(DiscoveryValidator.validate(data).isEmpty)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let paths = object?["paths"] as? [String: Any]
        let operation = (paths?["/free"] as? [String: Any])?["get"] as? [String: Any]
        let responses = operation?["responses"] as? [String: Any]
        #expect(operation?["x-payment-info"] == nil)
        #expect(responses?["402"] == nil)
        #expect(responses?["200"] != nil)
    }

    // MARK: semantic validate

    @Test("a payable operation without a 402 response is an error")
    func missing402IsError() {
        let json = Data(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/p":{"get":{"x-payment-info":{"amount":"1"},"requestBody":{"content":{}}}}}}
        """#.utf8)
        let errors = DiscoveryValidator.validate(json)
        #expect(errors.count == 1)
        #expect(errors.first?.severity == .error)
        #expect(errors.first?.message.contains("402") == true)
        #expect(errors.first?.path == "paths./p.get.responses")
    }

    @Test("a payable operation without a requestBody is a warning")
    func missingRequestBodyIsWarning() {
        let json = Data(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/p":{"get":{"x-payment-info":{"amount":"1"},
            "responses":{"402":{"description":"Payment Required"}}}}}}
        """#.utf8)
        let errors = DiscoveryValidator.validate(json)
        #expect(errors.count == 1)
        #expect(errors.first?.severity == .warning)
        #expect(errors.first?.message.contains("requestBody") == true)
    }

    @Test("a number in an operation schema does not break the semantic walk")
    func numberInSchemaTolerated() {
        // The requestBody schema carries a float; the semantic walk uses JSONSerialization (not the
        // integer-only JSONValue), so it tolerates the number and still flags the missing 402.
        let json = Data(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/p":{"get":{"x-payment-info":{"amount":"1"},
            "requestBody":{"content":{"application/json":{"schema":{"maximum":1.5}}}}}}}}
        """#.utf8)
        let errors = DiscoveryValidator.validate(json)
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("402") == true)
    }

    @Test("a free operation is not subjected to the payment semantic checks")
    func freeOperationNoSemanticErrors() {
        let json = Data(#"""
        {"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{
          "/free":{"get":{"summary":"free"}}}}
        """#.utf8)
        #expect(DiscoveryValidator.validate(json).isEmpty)
    }

    @Test("the conventional discovery path and media type")
    func conventionalPath() {
        #expect(DiscoveryDocument.conventionalPath == "/openapi.json")
        #expect(DiscoveryDocument.mediaType == "application/json")
    }
}
