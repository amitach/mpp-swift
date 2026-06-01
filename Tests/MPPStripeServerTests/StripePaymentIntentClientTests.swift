import Foundation
import HTTPTypes
import MPPClient
import Testing
@testable import MPPStripeServer

@Suite("StripePaymentIntentClient")
struct StripePaymentIntentClientTests {
    private func loopbackURL() throws -> URL {
        try #require(URL(string: "http://127.0.0.1:9999"))
    }

    private func sampleRequest() -> StripePaymentIntentRequest {
        StripePaymentIntentRequest(
            amount: 1000,
            currency: "usd",
            sharedPaymentGrantedToken: "spt_x",
            description: "a coffee",
            metadata: ["plan": "pro", "mpp_version": "1"],
            idempotencyKey: "idem_1",
            settlement: StripeConnectSettlement(
                applicationFeeAmount: 10,
                transferData: StripeTransferData(destination: "acct_dest", amount: 50),
                stripeAccount: "acct_conn"
            )
        )
    }

    @Test("a plain-http base URL is rejected; loopback is allowed only with the opt-in")
    func tlsGuard() throws {
        let transport = StubTransport(status: 200, body: Data())
        let plainHTTP = try #require(URL(string: "http://api.stripe.com"))
        #expect(throws: StripeAPIError.self) {
            _ = try StripePaymentIntentClient(
                transport: transport,
                secretKey: "sk",
                baseURL: plainHTTP
            )
        }
        // Loopback under the opt-in succeeds.
        _ = try StripePaymentIntentClient(
            transport: transport, secretKey: "sk", baseURL: loopbackURL(), allowInsecureLocal: true
        )
    }

    @Test("the form body is ordered + percent-encoded, automatic_payment_methods only")
    func formBody() async throws {
        let transport = StubTransport(
            status: 200, body: Data(#"{"id":"pi_1","status":"succeeded"}"#.utf8)
        )
        let client = try StripePaymentIntentClient(
            transport: transport, secretKey: "sk_test", baseURL: loopbackURL(),
            allowInsecureLocal: true
        )
        _ = try await client.create(sampleRequest())
        let captured = await transport.capturedBody
        let bodyData = try #require(captured)
        let text = try #require(String(bytes: bodyData, encoding: .utf8))
        #expect(text.hasPrefix(
            "amount=1000&automatic_payment_methods%5Ballow_redirects%5D=never"
                + "&automatic_payment_methods%5Benabled%5D=true&confirm=true&currency=usd"
                + "&shared_payment_granted_token=spt_x"
        ))
        #expect(text.contains("description=a+coffee"))
        #expect(text.contains("metadata%5Bplan%5D=pro"))
        #expect(text.contains("metadata%5Bmpp_version%5D=1"))
        #expect(text.contains("application_fee_amount=10"))
        #expect(text.contains("transfer_data%5Bdestination%5D=acct_dest"))
        #expect(text.contains("transfer_data%5Bamount%5D=50"))
        #expect(!text.contains("payment_method_types"))
        #expect(!text.contains("payment_method="))
    }

    @Test("auth, idempotency, version, and Stripe-Account headers are set")
    func headers() async throws {
        let transport = StubTransport(
            status: 200, body: Data(#"{"id":"pi_1","status":"succeeded"}"#.utf8)
        )
        let client = try StripePaymentIntentClient(
            transport: transport, secretKey: "sk_test", baseURL: loopbackURL(),
            allowInsecureLocal: true
        )
        _ = try await client.create(sampleRequest())
        let captured = await transport.capturedRequest
        let request = try #require(captured)
        let fields = request.headerFields
        let expectedAuth = "Basic " + Data("sk_test:".utf8).base64EncodedString()
        #expect(fields[.authorization] == expectedAuth)
        #expect(fields[.contentType] == "application/x-www-form-urlencoded")
        #expect(header(fields, "Idempotency-Key") == "idem_1")
        #expect(header(fields, "Stripe-Version") == "2026-02-25.preview")
        #expect(header(fields, "Stripe-Account") == "acct_conn")
        #expect(request.path == "/v1/payment_intents")
    }

    @Test("a 2xx response parses id + status; idempotent-replayed header sets replayed")
    func parsesResult() async throws {
        let replayedTransport = StubTransport(
            status: 200,
            headers: headerFields([("idempotent-replayed", "true")]),
            body: Data(#"{"id":"pi_2","status":"succeeded"}"#.utf8)
        )
        let client = try StripePaymentIntentClient(
            transport: replayedTransport, secretKey: "sk", baseURL: loopbackURL(),
            allowInsecureLocal: true
        )
        let result = try await client.create(sampleRequest())
        #expect(result.id == "pi_2")
        #expect(result.status == "succeeded")
        #expect(result.replayed)
    }

    @Test("a non-2xx response surfaces Stripe's error.message (no secret)")
    func stripeError() async throws {
        let transport = StubTransport(
            status: 402,
            body: Data(
                #"{"error":{"type":"invalid_request_error","message":"No such token: spt_x"}}"#
                    .utf8
            )
        )
        let client = try StripePaymentIntentClient(
            transport: transport, secretKey: "sk_test_secret", baseURL: loopbackURL(),
            allowInsecureLocal: true
        )
        do {
            // `create` uses typed throws, so a plain `catch` binds the StripeAPIError directly.
            _ = try await client.create(sampleRequest())
            Issue.record("expected a StripeAPIError")
        } catch {
            guard case let .stripeError(message) = error else {
                Issue.record("expected stripeError, got \(error)"); return
            }
            #expect(message == "No such token: spt_x")
            let leaksSecret = message.contains("sk_test_secret")
            #expect(!leaksSecret)
        }
    }
}
