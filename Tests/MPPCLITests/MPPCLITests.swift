import Foundation
import HTTPTypes
import MPPAuth
import MPPClient
import MPPCore
import MPPStripe
import Testing
@testable import mpp

// MARK: - Local test doubles (the MPPClient ones are not visible across the target boundary)

private func fieldName(_ token: String) -> HTTPField.Name {
    guard let name = HTTPField.Name(token) else { preconditionFailure("valid field name") }
    return name
}

private func tempo() throws -> MethodName {
    try MethodName("tempo")
}

private func chargeChallenge() throws -> Challenge {
    try Challenge(
        id: "c1", realm: "api.example.com", method: tempo(),
        intent: .charge, request: EncodedJSON("e30")
    )
}

private func response(_ code: Int, _ headers: HTTPFields = [:]) -> (HTTPResponse, Data) {
    (HTTPResponse(status: .init(code: code), headerFields: headers), Data())
}

private func getRequest() -> HTTPRequest {
    HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/r")
}

/// A transport that returns queued responses in order and records what it sent.
private final class StubTransport: MPPHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [(HTTPResponse, Data)]
    private var requests: [HTTPRequest] = []

    init(_ responses: [(HTTPResponse, Data)]) {
        queued = responses
    }

    func send(_ request: HTTPRequest, body _: Data) async throws -> (HTTPResponse, Data) {
        next(request)
    }

    private func next(_ request: HTTPRequest) -> (HTTPResponse, Data) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        guard !queued.isEmpty else { preconditionFailure("stub transport ran out of responses") }
        return queued.removeFirst()
    }

    var sentCount: Int {
        lock.lock(); defer { lock.unlock() }; return requests.count
    }
}

/// A method that supports the tempo challenge and builds a dummy credential.
private struct StubMethod: PaymentMethodClient {
    func supports(_ challenge: Challenge) -> Bool {
        (try? challenge.method == MethodName("tempo")) ?? false
    }

    func buildCredential(for challenge: Challenge) async throws -> Credential {
        Credential(challenge: challenge, payload: ["proof": "stub"])
    }
}

// MARK: - AuthorizerFactory (the headless-safety rules from the security review)

@Suite("AuthorizerFactory")
struct AuthorizerFactoryTests {
    @Test("non-interactive auto with a cap is a spending cap")
    func headlessWithCap() throws {
        let auth = try AuthorizerFactory.make(
            approve: .auto,
            maxAmount: Amount("100"),
            interactive: false
        )
        #expect(auth is SpendingCapAuthorizer)
    }

    @Test("non-interactive auto with no cap is refused (no unbounded headless spend)")
    func headlessWithoutCapRefused() {
        #expect(throws: CLIError.self) {
            try AuthorizerFactory.make(approve: .auto, maxAmount: nil, interactive: false)
        }
    }

    @Test("the default with no terminal resolves to auto, so it also requires a cap")
    func defaultHeadlessRequiresCap() {
        #expect(throws: CLIError.self) {
            try AuthorizerFactory.make(approve: nil, maxAmount: nil, interactive: false)
        }
    }

    @Test("a tty prompt is refused without a terminal")
    func ttyRequiresTerminal() {
        #expect(throws: CLIError.self) {
            try AuthorizerFactory.make(approve: .tty, maxAmount: nil, interactive: false)
        }
    }

    @Test("a biometric prompt is refused without a terminal")
    func biometricRequiresTerminal() {
        #expect(throws: CLIError.self) {
            try AuthorizerFactory.make(approve: .biometric, maxAmount: nil, interactive: false)
        }
    }

    @Test("an interactive tty default is a terminal authorizer")
    func interactiveDefaultIsTTY() throws {
        let auth = try AuthorizerFactory.make(approve: nil, maxAmount: nil, interactive: true)
        #expect(auth is TTYPaymentAuthorizer)
    }
}

// MARK: - ClientKeyLoader

@Suite("ClientKeyLoader")
struct ClientKeyLoaderTests {
    // viem private key 0x..01 (the proof-vector key), 0x-prefixed 32-byte hex.
    private let validKey = "0x0000000000000000000000000000000000000000000000000000000000000001"

    @Test("no key configured yields no methods")
    func empty() throws {
        #expect(try ClientKeyLoader.methods(from: [:]).isEmpty)
    }

    @Test("a valid MPP_PRIVATE_KEY yields the Tempo method")
    func tempoFromKey() throws {
        let methods = try ClientKeyLoader.methods(from: ["MPP_PRIVATE_KEY": validKey])
        #expect(methods.count == 1)
    }

    @Test("an MPP_STRIPE_SPT yields the Stripe method")
    func stripeFromSPT() throws {
        let methods = try ClientKeyLoader.methods(from: ["MPP_STRIPE_SPT": "spt_test_123"])
        #expect(methods.count == 1)
    }

    @Test("a present but non-hex MPP_PRIVATE_KEY is rejected, not silently skipped")
    func invalidKeyRejected() {
        #expect(throws: CLIError.self) {
            try ClientKeyLoader.methods(from: ["MPP_PRIVATE_KEY": "not-a-key"])
        }
    }
}

// MARK: - CLIOutcome (exit-code mapping)

@Suite("CLIOutcome")
struct CLIOutcomeTests {
    @Test("maps each error class to its curl/mppx exit code")
    func exitCodes() {
        #expect(CLIOutcome(error: PaymentDenied.amountUnknown).exitCode == 75)
        #expect(CLIOutcome(error: CLIError.noPaymentMethod).exitCode == 69)
        #expect(CLIOutcome(error: CLIError.unboundedHeadlessSpend).exitCode == 2)
        #expect(CLIOutcome(error: CLIError.invalidURL("x")).exitCode == 2)
        #expect(CLIOutcome(error: CLIError.invalidMethod("BAD METHOD")).exitCode == 2)
        #expect(CLIOutcome(error: PaymentClientError.insecureTransport(url: "http://x"))
            .exitCode == 60)
        #expect(CLIOutcome(error: PaymentClientError.noSupportedMethod).exitCode == 75)
        #expect(CLIOutcome(error: StripeMethodError.wrongMethodOrIntent).exitCode == 77)
        #expect(CLIOutcome(error: CLIError.httpError(status: 500)).exitCode == 22)
    }
}

// MARK: - Header parsing

@Suite("Pay header parsing")
struct HeaderParsingTests {
    @Test("parses a Name: Value header and rejects a malformed one")
    func parses() throws {
        let parsed = try #require(Pay.parseHeader("Content-Type: application/json"))
        #expect(parsed.0 == fieldName("Content-Type"))
        #expect(parsed.1 == "application/json")
        #expect(Pay.parseHeader("no-colon") == nil)
    }
}

// MARK: - Verbose progress lines

@Suite("verbose progress")
struct VerboseLineTests {
    @Test("formats the challenge and sanitizes a server-controlled realm")
    func formatsAndSanitizes() throws {
        let challenge = try Challenge(
            id: "c", realm: "api\u{202E}\u{1B}[2K.example.com", method: tempo(),
            intent: .charge, request: EncodedJSON("e30")
        )
        let line = verboseLine(for: .challengeReceived(challenge))
        #expect(line.contains("tempo/charge"))
        #expect(!line.unicodeScalars.contains("\u{202E}")) // bidi override stripped
        #expect(!line.unicodeScalars.contains("\u{1B}")) // escape stripped
    }

    @Test("a built credential line carries no secret material")
    func credentialLineHasNoSecret() throws {
        let credential = try Credential(challenge: chargeChallenge(), payload: ["proof": "SECRET"])
        #expect(verboseLine(for: .credentialCreated(credential)) == "* credential built")
    }
}

// MARK: - PayRunner flow (over a stub transport, no network)

@Suite("PayRunner")
struct PayRunnerTests {
    @Test("pays a 402 and surfaces the receipt")
    func paysAndCapturesReceipt() async throws {
        var offered = HTTPFields()
        offered[.wwwAuthenticate] = try chargeChallenge().headerValue
        let receipt = try Receipt(
            method: tempo(), timestamp: RFC3339DateTime("2026-01-02T00:00:00Z"), reference: "0xabc"
        )
        var paid = HTTPFields()
        paid[fieldName("Payment-Receipt")] = try receipt.headerValue

        let transport = StubTransport([response(402, offered), response(200, paid)])
        let runner = PayRunner(
            transport: transport, authorizer: AllowAllAuthorizer(),
            methods: [StubMethod()], allowInsecureLocal: false
        )
        let result = try await runner.run(request: getRequest(), body: Data())
        #expect(result.status == 200)
        #expect(result.receipt?.reference == "0xabc")
        #expect(transport.sentCount == 2) // exactly one paid retry
    }
}
