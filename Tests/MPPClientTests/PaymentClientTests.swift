import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import Testing

// Spec: draft-httpauth-payment-00 §4 (402 flow). The client sends, and on a 402
// parses WWW-Authenticate, selects a supported challenge, has the method build a
// credential, replays once with Authorization: Payment, and surfaces any
// Payment-Receipt. No network: the flow runs over a stub transport.

// MARK: - Fixtures

private func fieldName(_ token: String) -> HTTPField.Name {
    guard let name = HTTPField.Name(token) else { preconditionFailure("valid field name") }
    return name
}

private func paymentReceiptName() -> HTTPField.Name {
    fieldName("Payment-Receipt")
}

private func acceptPaymentName() -> HTTPField.Name {
    fieldName("Accept-Payment")
}

/// A transport that returns queued responses in order and records what it sent.
private final class StubTransport: MPPHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [(HTTPResponse, Data)]
    private var recorded: [HTTPRequest] = []

    init(_ responses: [(HTTPResponse, Data)]) {
        queued = responses
    }

    func send(_ request: HTTPRequest, body _: Data) async throws -> (HTTPResponse, Data) {
        next(request) // locking lives in a sync method (NSLock is unavailable in async)
    }

    private func next(_ request: HTTPRequest) -> (HTTPResponse, Data) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        guard !queued.isEmpty else { preconditionFailure("stub transport ran out of responses") }
        return queued.removeFirst()
    }

    var sent: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
}

/// A method that pays challenges whose `method` name matches.
private struct StubMethod: PaymentMethodClient {
    let methodName: MethodName
    func supports(_ challenge: Challenge) -> Bool {
        challenge.method == methodName
    }

    func buildCredential(for challenge: Challenge) async throws -> Credential {
        Credential(challenge: challenge, payload: ["proof": "stub"])
    }
}

private func tempo() throws -> MethodName {
    try MethodName("tempo")
}

private func challenge(method: MethodName) -> Challenge {
    Challenge(
        id: "challenge-1", realm: "api.example.com", method: method,
        intent: .charge, request: EncodedJSON("e30")
    )
}

private func response(_ code: Int, headers: HTTPFields = [:]) -> (HTTPResponse, Data) {
    (HTTPResponse(status: .init(code: code), headerFields: headers), Data())
}

private func request(
    scheme: String = "https",
    authority: String = "api.example.com"
) -> HTTPRequest {
    HTTPRequest(method: .get, scheme: scheme, authority: authority, path: "/r")
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ClientEvent] = []
    func add(_ event: ClientEvent) {
        lock.lock(); stored.append(event); lock.unlock()
    }

    var events: [ClientEvent] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

private func eventNames(_ box: EventBox) -> [String] {
    box.events.map { event in
        switch event {
        case .challengeReceived: "challengeReceived"
        case .credentialCreated: "credentialCreated"
        case .paymentResponse: "paymentResponse"
        case .paymentFailed: "paymentFailed"
        }
    }
}

// MARK: - Tests

@Suite("PaymentClient")
struct PaymentClientTests {
    @Test("a non-402 response is returned untouched, with no retry")
    func passthrough() async throws {
        let transport = StubTransport([response(200)])
        let client = try PaymentClient(
            transport: transport,
            methods: [StubMethod(methodName: tempo())]
        )
        let (response, _) = try await client.send(request())
        #expect(response.status.code == 200)
        #expect(transport.sent.count == 1)
    }

    @Test("a 402 is paid: select, build, retry once with Authorization, surface the receipt")
    func fullRoundTrip() async throws {
        let box = EventBox()
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: tempo()).headerValue
        let receipt = try Receipt(
            method: tempo(), timestamp: RFC3339DateTime("2026-01-02T00:00:00Z"), reference: "0xabc"
        )
        var paid = HTTPFields()
        paid[paymentReceiptName()] = try receipt.headerValue

        let transport = StubTransport([
            response(402, headers: offered),
            response(200, headers: paid),
        ])
        let client = try PaymentClient(
            transport: transport, methods: [StubMethod(methodName: tempo())], onEvent: box.add
        )
        let (response, _) = try await client.send(request())

        #expect(response.status.code == 200)
        #expect(transport.sent.count == 2) // exactly one retry
        // The retry carries the credential; the first request does not.
        #expect(transport.sent[0].headerFields[.authorization] == nil)
        #expect(transport.sent[1].headerFields[.authorization]?.hasPrefix("Payment ") == true)
        #expect(eventNames(box) == ["challengeReceived", "credentialCreated", "paymentResponse"])
        // The surfaced receipt round-trips.
        guard case let .paymentResponse(parsed) = box.events.last else {
            Issue.record("expected paymentResponse"); return
        }
        #expect(parsed == receipt)
    }

    @Test("a 402 whose challenge no method supports throws noSupportedMethod, no retry")
    func noSupportedMethod() async throws {
        let box = EventBox()
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: MethodName("stripe")).headerValue
        let transport = StubTransport([response(402, headers: offered)])
        let client = try PaymentClient(
            transport: transport, methods: [StubMethod(methodName: tempo())], onEvent: box.add
        )
        await #expect(throws: PaymentClientError.noSupportedMethod) {
            try await client.send(request())
        }
        #expect(transport.sent.count == 1)
        #expect(eventNames(box) == ["paymentFailed"])
    }

    @Test("a 402 with no parseable Payment challenge throws malformedChallenge")
    func malformedChallenge() async throws {
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = "Bearer realm=\"x\"" // not a Payment challenge
        let transport = StubTransport([response(402, headers: offered)])
        let client = try PaymentClient(
            transport: transport,
            methods: [StubMethod(methodName: tempo())]
        )
        await #expect(throws: PaymentClientError.malformedChallenge) {
            try await client.send(request())
        }
    }

    @Test("non-https is rejected unless allowInsecureLocal permits a loopback host")
    func transportSecurity() async throws {
        let methods = try [StubMethod(methodName: tempo())]
        // Plain http, no opt-in: rejected before any send.
        let plain = StubTransport([response(200)])
        await #expect(throws: PaymentClientError.self) {
            try await PaymentClient(transport: plain, methods: methods)
                .send(request(scheme: "http"))
        }
        #expect(plain.sent.isEmpty)
        // Opt-in + loopback: allowed.
        let loopback = StubTransport([response(200)])
        let local = PaymentClient(transport: loopback, methods: methods, allowInsecureLocal: true)
        let (served, _) = try await local.send(request(
            scheme: "http",
            authority: "localhost:8080"
        ))
        #expect(served.status.code == 200)
        // Opt-in but non-loopback http: still rejected.
        let remote = StubTransport([response(200)])
        await #expect(throws: PaymentClientError.self) {
            try await PaymentClient(transport: remote, methods: methods, allowInsecureLocal: true)
                .send(request(scheme: "http", authority: "api.example.com"))
        }
        #expect(remote.sent.isEmpty)
    }

    @Test("Accept-Payment is injected only when the policy allows it")
    func acceptPaymentInjection() async throws {
        let methods = try [StubMethod(methodName: tempo())]
        // policy .always + advertise -> header injected on the outgoing request.
        let allowed = StubTransport([response(200)])
        _ = try await PaymentClient(transport: allowed, methods: methods, advertise: "tempo/charge")
            .send(request())
        #expect(allowed.sent[0].headerFields[acceptPaymentName()] == "tempo/charge")
        // policy .never -> not injected.
        let denied = StubTransport([response(200)])
        _ = try await PaymentClient(
            transport: denied, methods: methods, acceptPaymentPolicy: .never,
            advertise: "tempo/charge"
        ).send(request())
        #expect(denied.sent[0].headerFields[acceptPaymentName()] == nil)
    }
}
