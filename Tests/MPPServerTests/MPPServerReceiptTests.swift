import Foundation
import HTTPTypes
import MPPCore
import MPPServer
import Testing

// The middleware mints and attaches a Payment-Receipt (base64url JSON; optional
// per draft-httpauth-payment-00, for auditability) on a successful paid response
// when a payment method settled the credential, and attaches nothing in
// protocol-only mode. AcceptingMethod is defined in PaymentVerifierTests (same
// target).
@Suite("MPPServerMiddleware Payment-Receipt")
struct MPPServerReceiptTests {
    /// The response from driving a valid paid request through a middleware whose
    /// verifier has `methods` registered.
    private func paidResponse(methods: [any PaymentMethodServer]) async throws -> HTTPResponse {
        let middleware = try makeMiddleware(methods: methods)
        let request = try makeRequest(authorization: paidHeader())
        return await middleware.handle(request, body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data("ok".utf8))
        }.0
    }

    @Test("a paid response carries the Payment-Receipt header when a method settles")
    func attachesReceipt() async throws {
        let response = try await paidResponse(methods: [AcceptingMethod(reference: "0xtxref")])
        let field = try #require(HTTPField.Name("Payment-Receipt"))
        let value = try #require(response.headerFields[field])
        let receipt = try Receipt(headerValue: value)
        #expect(receipt.reference == "0xtxref")
        #expect(receipt.method.rawValue == "tempo")
        #expect(receipt.status == .success)
    }

    @Test("protocol-only verification attaches no Payment-Receipt header")
    func noReceiptWithoutMethod() async throws {
        let response = try await paidResponse(methods: [])
        let field = try #require(HTTPField.Name("Payment-Receipt"))
        #expect(response.headerFields[field] == nil)
    }
}
