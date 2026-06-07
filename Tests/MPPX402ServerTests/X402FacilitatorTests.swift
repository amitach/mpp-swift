import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import MPPX402
import MPPX402Server
import Testing

// The x402 facilitator client and the FacilitatorSettlement that settles through it. A stub
// MPPHTTPTransport returns crafted /verify and /settle JSON and records the posted body, so the
// request shape, the response parsing, and the X402Settlement conformance are proven without a
// network. The live facilitator e2e is gated/external (needs a real facilitator + funded payer).
@Suite("X402 facilitator")
struct X402FacilitatorTests {
    private static let usdcHex = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    private static let payerHex = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    private static let payToHex = "0x1111111111111111111111111111111111111111"

    private func baseURL() throws -> URL {
        try #require(URL(string: "https://facilitator.example"))
    }

    private func domain() throws -> X402Domain {
        try X402Domain(
            name: "USD Coin", version: "2", chainId: 84532,
            asset: #require(EthereumAddress(hex: Self.usdcHex))
        )
    }

    private func authorization() throws -> X402Authorization {
        let from = try #require(EthereumAddress(hex: Self.payerHex))
        let recipient = try #require(EthereumAddress(hex: Self.payToHex))
        return try #require(X402Authorization(
            from: from, recipient: recipient,
            value: Amount("1000000"), validAfter: 0, validBefore: 1_893_456_000,
            nonce: Data(repeating: 0xAB, count: 32)
        ))
    }

    private func paymentPayload() throws -> X402PaymentPayload {
        let exact = try X402ExactPayload(
            signature: "0x" + String(repeating: "ab", count: 65),
            authorization: authorization().wire
        )
        return X402PaymentPayload(version: .v1, network: .baseSepolia, payload: exact)
    }

    private func requirements() throws -> X402PaymentRequirements {
        try X402PaymentRequirements(
            network: .baseSepolia, amount: Amount("1000000"), asset: Self.usdcHex,
            payTo: Self.payToHex, maxTimeoutSeconds: 300,
            extra: ["name": .string("USD Coin"), "version": .string("2")]
        )
    }

    @Test("verify posts the payload + requirements and parses isValid")
    func verifyParses() async throws {
        let stub = StubTransport(json: .object([
            "isValid": .bool(true),
            "payer": .string(Self.payerHex),
        ]))
        let facilitator = try X402Facilitator(baseURL: baseURL(), transport: stub)
        let response = try await facilitator.verify(
            payment: paymentPayload(), requirements: requirements()
        )
        #expect(response.isValid)
        #expect(response.payer == Self.payerHex)
        // The request went to /verify with the version + both objects.
        #expect(stub.path == "/verify")
        let body = try #require(stub.bodyObject)
        #expect(body["x402Version"]?.integerValue == 1)
        #expect(body["paymentPayload"]?.objectValue != nil)
        #expect(body["paymentRequirements"]?.objectValue != nil)
    }

    @Test("settle parses success + the transaction hash")
    func settleParses() async throws {
        let stub = StubTransport(json: .object([
            "success": .bool(true), "transaction": .string("0xfeedface"),
            "network": .string("base-sepolia"), "payer": .string(Self.payerHex),
        ]))
        let facilitator = try X402Facilitator(baseURL: baseURL(), transport: stub)
        let response = try await facilitator.settle(
            payment: paymentPayload(), requirements: requirements()
        )
        #expect(response.success)
        #expect(response.transaction == "0xfeedface")
        #expect(stub.path == "/settle")
    }

    @Test("plain-http facilitator URL rejected; loopback allowed only under opt-in")
    func transportSecurity() throws {
        let insecure = try #require(URL(string: "http://facilitator.example"))
        #expect(throws: X402FacilitatorError.self) {
            try X402Facilitator(baseURL: insecure, transport: StubTransport(json: .object([:])))
        }
        // A loopback host over plain http is still rejected without the explicit opt-in.
        let loopback = try #require(URL(string: "http://127.0.0.1:8080"))
        #expect(throws: X402FacilitatorError.self) {
            try X402Facilitator(baseURL: loopback, transport: StubTransport(json: .object([:])))
        }
        // The opt-in permits a loopback facilitator mock over plain http.
        _ = try X402Facilitator(
            baseURL: loopback, transport: StubTransport(json: .object([:])),
            allowInsecureLocal: true
        )
    }

    @Test("settle rejects a reported success that omits the transaction hash")
    func settleRejectsSuccessWithoutTransaction() async throws {
        let stub = StubTransport(json: .object(["success": .bool(true)]))
        let facilitator = try X402Facilitator(baseURL: baseURL(), transport: stub)
        await #expect(
            throws: X402FacilitatorError.malformedResponse(
                "settle reported success without a transaction hash"
            )
        ) {
            _ = try await facilitator.settle(
                payment: paymentPayload(), requirements: requirements()
            )
        }
    }

    @Test("a non-2xx facilitator response surfaces as httpStatus")
    func httpStatusError() async throws {
        let stub = StubTransport(status: 502, json: .object([:]))
        let facilitator = try X402Facilitator(baseURL: baseURL(), transport: stub)
        await #expect(throws: X402FacilitatorError.httpStatus(502)) {
            _ = try await facilitator.settle(
                payment: paymentPayload(),
                requirements: requirements()
            )
        }
    }

    @Test("FacilitatorSettlement returns the settled hash, and throws on a reported failure")
    func facilitatorSettlement() async throws {
        let okStub = StubTransport(json: .object([
            "success": .bool(true), "transaction": .string("0xfeedface"),
        ]))
        let settler = try FacilitatorSettlement(
            facilitator: X402Facilitator(baseURL: baseURL(), transport: okStub), version: .v1
        )
        let hash = try await settler.settle(
            authorization: authorization(), domain: domain(),
            signature: Data(repeating: 0xCD, count: 65)
        )
        #expect(hash == "0xfeedface")
        // The reconstructed requirements carry the token + payee the authorization names.
        let body = try #require(okStub.bodyObject)
        let req = try #require(body["paymentRequirements"]?.objectValue)
        #expect(req["payTo"]?.stringValue?.lowercased() == Self.payToHex)
        #expect(req["asset"]?.stringValue?.lowercased() == Self.usdcHex.lowercased())
        // The timeout hint is the default duration (~300s), not the ~1.7-billion-second value that
        // validBefore - validAfter yields when validAfter is 0 (the common case).
        #expect(req["maxTimeoutSeconds"]?.integerValue == 300)

        let failing = StubTransport(json: .object([
            "success": .bool(false), "transaction": .string(""),
            "errorReason": .string("insufficient_funds"),
        ]))
        let denied = try FacilitatorSettlement(
            facilitator: X402Facilitator(baseURL: baseURL(), transport: failing)
        )
        await #expect(throws: FacilitatorSettlementError.settlementFailed("insufficient_funds")) {
            _ = try await denied.settle(
                authorization: authorization(), domain: domain(),
                signature: Data(repeating: 0xCD, count: 65)
            )
        }
    }
}

/// A stub ``MPPHTTPTransport`` that returns a fixed response and records the last request.
private final class StubTransport: MPPHTTPTransport, @unchecked Sendable {
    private let status: Int
    private let responseBody: Data
    private let lock = NSLock()
    private var lastPath: String?
    private var lastBody: Data?

    var path: String? {
        lock.withLock { lastPath }
    }

    var bodyObject: [String: JSONValue]? {
        guard let data = lock.withLock({ lastBody }),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json.objectValue
    }

    init(status: Int = 200, json: JSONValue) {
        self.status = status
        responseBody = Data(json.canonicalized().utf8)
    }

    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        lock.withLock {
            lastPath = request.path
            lastBody = body
        }
        return (HTTPResponse(status: .init(code: status)), responseBody)
    }
}
