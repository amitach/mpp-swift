import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import Testing

// Spec: draft-httpauth-payment-00 §4 (402 flow). The client sends, and on a 402
// parses WWW-Authenticate, selects a supported challenge, has the method build a
// credential, replays once with Authorization: Payment, and surfaces any
// Payment-Receipt. No network: the flow runs over a stub transport.

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

    @Test("a caller-set Accept-Payment header is not overwritten by advertise")
    func doesNotOverwriteCallerAcceptPayment() async throws {
        let transport = StubTransport([response(200)])
        var caller = request()
        caller.headerFields[acceptPaymentName()] = "stripe/charge"
        _ = try await PaymentClient(
            transport: transport, methods: [StubMethod(methodName: tempo())],
            advertise: "tempo/charge"
        ).send(caller)
        #expect(transport.sent[0].headerFields[acceptPaymentName()] == "stripe/charge")
    }

    // MARK: - Multi-challenge selection

    @Test("selects a supported challenge packed after an unsupported one on a single line")
    func selectsSupportedChallengeOnSingleLine() async throws {
        let box = EventBox()
        let packed = try [
            challenge(method: MethodName("stripe"), id: "s"),
            challenge(method: tempo(), id: "t"),
        ].map(\.headerValue).joined(separator: ", ")
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = packed
        let transport = StubTransport([response(402, headers: offered), response(200)])
        let client = try PaymentClient(
            transport: transport, methods: [StubMethod(methodName: tempo())], onEvent: box.add
        )
        let (response, _) = try await client.send(request())
        #expect(response.status.code == 200)
        #expect(selectedChallenge(box)?.id == "t")
    }

    @Test("selects a supported challenge offered on a separate WWW-Authenticate line")
    func selectsSupportedChallengeAcrossLines() async throws {
        let box = EventBox()
        var offered = HTTPFields()
        try offered.append(HTTPField(
            name: .wwwAuthenticate,
            value: challenge(method: MethodName("stripe"), id: "s").headerValue
        ))
        try offered.append(HTTPField(
            name: .wwwAuthenticate,
            value: challenge(method: tempo(), id: "t").headerValue
        ))
        let transport = StubTransport([response(402, headers: offered), response(200)])
        let client = try PaymentClient(
            transport: transport, methods: [StubMethod(methodName: tempo())], onEvent: box.add
        )
        _ = try await client.send(request())
        #expect(selectedChallenge(box)?.id == "t")
    }

    @Test("when several challenges are supported, the first offered is selected")
    func selectsFirstSupportedWhenSeveral() async throws {
        let box = EventBox()
        let packed = try [
            challenge(method: tempo(), id: "first"),
            challenge(method: MethodName("stripe"), id: "second"),
        ].map(\.headerValue).joined(separator: ", ")
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = packed
        let transport = StubTransport([response(402, headers: offered), response(200)])
        let methods: [any PaymentMethodClient] = try [
            StubMethod(methodName: tempo()), StubMethod(methodName: MethodName("stripe")),
        ]
        let client = PaymentClient(transport: transport, methods: methods, onEvent: box.add)
        _ = try await client.send(request())
        #expect(selectedChallenge(box)?.id == "first")
    }

    // MARK: - Hostile sequences

    @Test("a retry that also returns 402 is not retried again")
    func doesNotRetryASecondTime() async throws {
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: tempo()).headerValue
        let transport = StubTransport([
            response(402, headers: offered),
            response(402, headers: offered),
        ])
        let client = try PaymentClient(
            transport: transport,
            methods: [StubMethod(methodName: tempo())]
        )
        let (response, _) = try await client.send(request())
        #expect(response.status.code == 402)
        #expect(transport.sent.count == 2) // one original + one retry, never a third
    }

    @Test("a payment method's buildCredential error propagates unwrapped, with no retry")
    func methodBuildErrorPropagates() async throws {
        let box = EventBox()
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: tempo()).headerValue
        let transport = StubTransport([response(402, headers: offered)])
        let client = try PaymentClient(
            transport: transport, methods: [ThrowingMethod(methodName: tempo())], onEvent: box.add
        )
        await #expect(throws: StubError.boom) { try await client.send(request()) }
        #expect(transport.sent.count == 1) // no paid retry
        #expect(eventNames(box) == ["challengeReceived"]) // never credentialCreated/paymentResponse
    }

    @Test("a transport error on the retry propagates unwrapped")
    func transportErrorOnRetryPropagates() async throws {
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: tempo()).headerValue
        let transport = StubTransport([response(402, headers: offered)], throwOnCall: 2)
        let client = try PaymentClient(
            transport: transport,
            methods: [StubMethod(methodName: tempo())]
        )
        await #expect(throws: StubError.boom) { try await client.send(request()) }
        #expect(transport.sent.count == 2)
    }

    @Test("a non-base64url Payment-Receipt on the paid 200 surfaces as paymentResponse(nil)")
    func garbageReceiptSurfacesNil() async throws {
        let box = EventBox()
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: tempo()).headerValue
        var paid = HTTPFields()
        paid[paymentReceiptName()] = "!!!not-base64url!!!"
        let transport = StubTransport([
            response(402, headers: offered),
            response(200, headers: paid),
        ])
        let client = try PaymentClient(
            transport: transport, methods: [StubMethod(methodName: tempo())], onEvent: box.add
        )
        _ = try await client.send(request())
        guard case let .paymentResponse(receipt) = box.events.last else {
            Issue.record("expected paymentResponse"); return
        }
        #expect(receipt == nil)
    }

    @Test("the request body and caller headers are forwarded onto the paid retry")
    func forwardsBodyAndHeadersOnRetry() async throws {
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try challenge(method: tempo()).headerValue
        let transport = StubTransport([response(402, headers: offered), response(200)])
        let client = try PaymentClient(
            transport: transport,
            methods: [StubMethod(methodName: tempo())]
        )
        var caller = request()
        caller.headerFields[fieldName("X-Custom")] = "kept"
        let body = Data("payload".utf8)
        _ = try await client.send(caller, body: body)
        #expect(transport.sentBodies[1] == body) // body re-sent on the retry
        #expect(transport.sent[1].headerFields[fieldName("X-Custom")] == "kept")
        #expect(transport.sent[1].headerFields[.authorization]?.hasPrefix("Payment ") == true)
    }
}
