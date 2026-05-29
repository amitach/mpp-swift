import Foundation
import HTTPTypes
import MPPClient
import MPPCore

// Shared test fixtures for the MPPClient suites (one home, not duplicated).

func fieldName(_ token: String) -> HTTPField.Name {
    guard let name = HTTPField.Name(token) else { preconditionFailure("valid field name") }
    return name
}

func paymentReceiptName() -> HTTPField.Name {
    fieldName("Payment-Receipt")
}

func acceptPaymentName() -> HTTPField.Name {
    fieldName("Accept-Payment")
}

enum StubError: Error { case boom }

/// A transport that returns queued responses in order and records what it sent
/// (request and body), optionally throwing on a chosen 1-based call.
final class StubTransport: MPPHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [(HTTPResponse, Data)]
    private let throwOnCall: Int?
    private var requests: [HTTPRequest] = []
    private var bodies: [Data] = []

    init(_ responses: [(HTTPResponse, Data)], throwOnCall: Int? = nil) {
        queued = responses
        self.throwOnCall = throwOnCall
    }

    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        try next(request, body) // locking lives in a sync method (NSLock is unavailable in async)
    }

    private func next(_ request: HTTPRequest, _ body: Data) throws -> (HTTPResponse, Data) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        bodies.append(body)
        if requests.count == throwOnCall { throw StubError.boom }
        guard !queued.isEmpty else { preconditionFailure("stub transport ran out of responses") }
        return queued.removeFirst()
    }

    var sent: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }

    var sentBodies: [Data] {
        lock.lock(); defer { lock.unlock() }; return bodies
    }
}

/// A method that pays challenges whose `method` name matches.
struct StubMethod: PaymentMethodClient {
    let methodName: MethodName
    func supports(_ challenge: Challenge) -> Bool {
        challenge.method == methodName
    }

    func buildCredential(for challenge: Challenge) async throws -> Credential {
        Credential(challenge: challenge, payload: ["proof": "stub"])
    }
}

/// A method that matches but fails to build a credential.
struct ThrowingMethod: PaymentMethodClient {
    let methodName: MethodName
    func supports(_ challenge: Challenge) -> Bool {
        challenge.method == methodName
    }

    func buildCredential(for _: Challenge) async throws -> Credential {
        throw StubError.boom
    }
}

func tempo() throws -> MethodName {
    try MethodName("tempo")
}

func challenge(method: MethodName, id: String = "challenge-1") -> Challenge {
    Challenge(
        id: id, realm: "api.example.com", method: method,
        intent: .charge, request: EncodedJSON("e30")
    )
}

func response(_ code: Int, headers: HTTPFields = [:]) -> (HTTPResponse, Data) {
    (HTTPResponse(status: .init(code: code), headerFields: headers), Data())
}

func request(scheme: String = "https", authority: String = "api.example.com") -> HTTPRequest {
    HTTPRequest(method: .get, scheme: scheme, authority: authority, path: "/r")
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ClientEvent] = []
    func add(_ event: ClientEvent) {
        lock.lock(); stored.append(event); lock.unlock()
    }

    var events: [ClientEvent] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

func selectedChallenge(_ box: EventBox) -> Challenge? {
    for event in box.events {
        if case let .challengeReceived(challenge) = event { return challenge }
    }
    return nil
}

func eventNames(_ box: EventBox) -> [String] {
    box.events.map { event in
        switch event {
        case .challengeReceived: "challengeReceived"
        case .credentialCreated: "credentialCreated"
        case .paymentResponse: "paymentResponse"
        case .paymentFailed: "paymentFailed"
        }
    }
}
