import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import Testing

// The client consults a PaymentAuthorizer once, after selecting the challenge to pay
// and before the method builds a credential. Returning approves; throwing denies, and
// no credential is built (the error propagates unwrapped). The same seam gates the HTTP
// and MCP flows; here we exercise the HTTP `PaymentClient` and the built-in authorizers.

enum AuthorizerTestError: Error, Equatable { case denied }

/// Records the approval requests it saw, then approves.
final class RecordingAuthorizer: PaymentAuthorizer, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [PaymentApprovalRequest] = []
    func authorize(_ request: PaymentApprovalRequest) async throws {
        record(request) // locking lives in a sync method (NSLock is unavailable in async)
    }

    private func record(_ request: PaymentApprovalRequest) {
        lock.lock(); seen.append(request); lock.unlock()
    }

    var requests: [PaymentApprovalRequest] {
        lock.lock(); defer { lock.unlock() }; return seen
    }
}

/// Denies every spend with a sentinel error.
struct DenyingAuthorizer: PaymentAuthorizer {
    func authorize(_: PaymentApprovalRequest) async throws {
        throw AuthorizerTestError.denied
    }
}

/// A method that counts how often `buildCredential` is invoked, so a test can prove a
/// denial short-circuits it.
final class CountingMethod: PaymentMethodClient, @unchecked Sendable {
    let methodName: MethodName
    private let lock = NSLock()
    private var built = 0

    init(methodName: MethodName) {
        self.methodName = methodName
    }

    func supports(_ challenge: Challenge) -> Bool {
        challenge.method == methodName
    }

    func buildCredential(for challenge: Challenge) async throws -> Credential {
        increment() // locking lives in a sync method (NSLock is unavailable in async)
        return Credential(challenge: challenge, payload: ["proof": "stub"])
    }

    private func increment() {
        lock.lock(); built += 1; lock.unlock()
    }

    var buildCount: Int {
        lock.lock(); defer { lock.unlock() }; return built
    }
}

@Suite("PaymentAuthorizer (client flow)")
struct PaymentAuthorizerClientTests {
    @Test("approve: the flow proceeds to build and pay")
    func approveProceeds() async throws {
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: tempo()).headerValue
        let transport = StubTransport([response(402, headers: offered), response(200)])
        let client = try PaymentClient(
            transport: transport,
            methods: [StubMethod(methodName: tempo())],
            authorizer: AllowAllAuthorizer()
        )
        let (paid, _) = try await client.send(request())
        #expect(paid.status.code == 200)
        #expect(transport.sent.count == 2)
    }

    @Test("deny: throws unwrapped, builds no credential, sends no retry")
    func denyShortCircuits() async throws {
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: tempo()).headerValue
        let transport = StubTransport([response(402, headers: offered)])
        let method = try CountingMethod(methodName: tempo())
        let client = PaymentClient(
            transport: transport, methods: [method], authorizer: DenyingAuthorizer()
        )
        await #expect(throws: AuthorizerTestError.denied) {
            _ = try await client.send(request())
        }
        #expect(method.buildCount == 0) // the credential was never built
        #expect(transport.sent.count == 1) // and no paid retry was sent
    }

    @Test("the authorizer is consulted exactly once, for the selected challenge")
    func gatesSelectedChallenge() async throws {
        let recorder = RecordingAuthorizer()
        var offered = HTTPFields()
        try offered.append(HTTPField(
            name: .wwwAuthenticate,
            value: challenge(method: MethodName("stripe"), id: "c-stripe").headerValue
        ))
        try offered.append(HTTPField(
            name: .wwwAuthenticate,
            value: challenge(method: tempo(), id: "c-tempo").headerValue
        ))
        let transport = StubTransport([response(402, headers: offered), response(200)])
        let client = try PaymentClient(
            transport: transport, methods: [StubMethod(methodName: tempo())], authorizer: recorder
        )
        _ = try await client.send(request())
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.challengeId == "c-tempo")
        #expect(try recorder.requests.first?.method == tempo())
    }

    @Test("the default approvalFacts carries only the rail-agnostic challenge fields")
    func defaultApprovalFactsIsGeneric() throws {
        let offered = try challenge(method: tempo(), id: "c1")
        let facts = try StubMethod(methodName: tempo()).approvalFacts(for: offered)
        #expect(facts.challengeId == "c1")
        #expect(facts.realm == "api.example.com")
        #expect(try facts.method == tempo())
        #expect(facts.intent == .charge)
        #expect(facts.amount == nil)
        #expect(facts.currency == nil)
        #expect(facts.recipient == nil)
    }
}

@Suite("SpendingCapAuthorizer")
struct SpendingCapAuthorizerTests {
    private func request(
        amount: Amount?,
        currency: String? = nil
    ) throws -> PaymentApprovalRequest {
        try PaymentApprovalRequest(
            challengeId: "c", realm: "api.example.com",
            method: MethodName("tempo"), intent: .charge,
            amount: amount, currency: currency, recipient: nil,
            description: nil, expires: nil
        )
    }

    @Test("an amount under the cap is approved")
    func underCap() async throws {
        let auth = try SpendingCapAuthorizer(maxAmount: Amount("100"))
        let req = try request(amount: Amount("50"))
        try await auth.authorize(req)
    }

    @Test("an amount equal to the cap is approved")
    func atCap() async throws {
        let auth = try SpendingCapAuthorizer(maxAmount: Amount("100"))
        let req = try request(amount: Amount("100"))
        try await auth.authorize(req)
    }

    @Test("an amount over the cap is denied")
    func overCap() async throws {
        let amount = try Amount("101")
        let cap = try Amount("100")
        let auth = SpendingCapAuthorizer(maxAmount: cap)
        let req = try request(amount: amount)
        await #expect(throws: PaymentDenied.overCap(amount: amount, cap: cap)) {
            try await auth.authorize(req)
        }
    }

    @Test("an unknown amount fails closed")
    func unknownAmount() async throws {
        let auth = try SpendingCapAuthorizer(maxAmount: Amount("100"))
        let req = try request(amount: nil)
        await #expect(throws: PaymentDenied.amountUnknown) {
            try await auth.authorize(req)
        }
    }

    @Test("a matching currency within the cap is approved")
    func currencyMatch() async throws {
        let auth = try SpendingCapAuthorizer(maxAmount: Amount("100"), currency: "usd")
        let req = try request(amount: Amount("50"), currency: "usd")
        try await auth.authorize(req)
    }

    @Test("the currency match is case-insensitive (usd == USD)")
    func currencyMatchCaseInsensitive() async throws {
        let auth = try SpendingCapAuthorizer(maxAmount: Amount("100"), currency: "usd")
        let req = try request(amount: Amount("50"), currency: "USD")
        try await auth.authorize(req)
    }

    @Test("a currency mismatch is denied")
    func currencyMismatch() async throws {
        let auth = try SpendingCapAuthorizer(maxAmount: Amount("100"), currency: "usd")
        let req = try request(amount: Amount("50"), currency: "eur")
        await #expect(throws: PaymentDenied.currencyMismatch(expected: "usd", got: "eur")) {
            try await auth.authorize(req)
        }
    }
}
