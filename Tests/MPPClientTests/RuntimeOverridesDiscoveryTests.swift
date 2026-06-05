import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPDiscovery
import Testing

// B14: the discovery price is advisory; the live 402 challenge is authoritative. The client never
// consults the discovery document to decide what to pay -- it pays exactly the amount the live 402
// carries. This integration test pins that: discovery advertises one price, the 402 carries a
// different one, and the client authorizes and pays the 402's.
@Suite("Runtime 402 overrides discovery (B14)")
struct RuntimeOverridesDiscoveryTests {
    /// The amount field decoded from a challenge's method-specific request.
    private struct AmountWire: Decodable { let amount: String }

    /// A method that decodes the charge amount from the live challenge's request, so the authorizer
    /// sees the price the 402 actually carries (not anything discovery advertised).
    private struct AmountAwareMethod: PaymentMethodClient {
        let methodName: MethodName
        func supports(_ challenge: Challenge) -> Bool {
            challenge.method == methodName
        }

        func buildCredential(for challenge: Challenge) async throws -> Credential {
            Credential(challenge: challenge, payload: ["proof": "stub"])
        }

        func approvalFacts(for challenge: Challenge) -> PaymentApprovalRequest {
            let amount = (try? challenge.request.decode(as: AmountWire.self))
                .flatMap { try? Amount($0.amount) }
            return PaymentApprovalRequest(
                challengeId: challenge.id, realm: challenge.realm, method: challenge.method,
                intent: challenge.intent, amount: amount, currency: nil, recipient: nil,
                description: challenge.description, expires: challenge.expires
            )
        }
    }

    /// Captures the single approval request the flow presents to the authorizer.
    private actor RecordingAuthorizer: PaymentAuthorizer {
        private(set) var seen: PaymentApprovalRequest?

        func authorize(_ request: PaymentApprovalRequest) async throws {
            seen = request
        }
    }

    private func challengeCarrying(amount: String, method: MethodName) -> Challenge {
        Challenge(
            id: "challenge-1", realm: "api.example.com", method: method,
            intent: .charge, request: EncodedJSON(json: .object(["amount": .string(amount)]))
        )
    }

    @Test(
        "the client authorizes and pays the live 402's amount, not the advertised discovery price"
    )
    func liveChallengeOverridesDiscovery() async throws {
        let method = try tempo()

        // What discovery advertises (advisory only): 1000.
        let advertisedAmount = try Amount("1000")
        let discovery = try #require(PaymentInfo(offers: [
            PaymentOffer(
                amount: .fixed(advertisedAmount), currency: "USD", intent: "charge", method: "tempo"
            ),
        ]))
        #expect(discovery.offers.first?.amount == .fixed(advertisedAmount))

        // What the live 402 actually charges (authoritative): 2500, different from discovery.
        let liveAmount = try Amount("2500")
        let challenge = challengeCarrying(amount: liveAmount.rawValue, method: method)
        let transport = StubTransport([
            response(402, headers: [.wwwAuthenticate: challenge.headerValue]),
            response(200),
        ])
        let authorizer = RecordingAuthorizer()
        let client = PaymentClient(
            transport: transport,
            methods: [AmountAwareMethod(methodName: method)],
            authorizer: authorizer
        )

        let (paid, _) = try await client.send(request())
        #expect(paid.status.code == 200)
        // The amount the client authorized is the 402's, never the discovery-advertised one.
        let authorized = await authorizer.seen?.amount
        #expect(authorized == liveAmount)
        #expect(authorized != advertisedAmount)
        // It really ran the pay flow: an unpaid 402 then a credentialed retry.
        #expect(transport.sent.count == 2)
        #expect(transport.sent.last?.headerFields[.authorization] != nil)
    }
}
