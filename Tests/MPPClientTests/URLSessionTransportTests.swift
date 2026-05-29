import Foundation
import HTTPTypes
import Testing
@testable import MPPClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// URLSessionTransport driven through a real URLSession whose protocol stack is a
// custom URLProtocol stub: it captures the outgoing request and returns a canned
// response, so the HTTPRequest <-> URLRequest <-> HTTPResponse mapping is exercised
// end-to-end with no network. Serialized because the stub's handler is shared
// static state (one request in flight at a time).
@Suite("URLSessionTransport", .serialized)
struct URLSessionTransportTests {
    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func response(
        _ request: URLRequest, _ code: Int, _ headers: [String: String]? = nil
    ) throws -> HTTPURLResponse {
        let url = try #require(request.url)
        return try #require(
            HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)
        )
    }

    @Test("a GET maps method/url/headers out and status/headers/body back")
    func getRoundTrip() async throws {
        StubURLProtocol.respond { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://api.example.com/resource")
            #expect(request.value(forHTTPHeaderField: "X-Test") == "abc")
            return try (
                self.response(request, 200, ["Content-Type": "application/json"]),
                Data(#"{"ok":true}"#.utf8)
            )
        }
        var request = HTTPRequest(
            method: .get, scheme: "https", authority: "api.example.com", path: "/resource"
        )
        try request.headerFields[#require(.init("X-Test"))] = "abc"

        let (response, body) = try await URLSessionTransport(session: stubbedSession())
            .send(request, body: Data())
        #expect(response.status == .ok)
        #expect(response.headerFields[.contentType] == "application/json")
        #expect(body == Data(#"{"ok":true}"#.utf8))
    }

    @Test("a POST carries the request body")
    func postSendsBody() async throws {
        let sent = Data("challenge-credential-bytes".utf8)
        StubURLProtocol.respond { request in
            #expect(request.httpMethod == "POST")
            // The upload body is delivered by URLSession but is not exposed to a
            // URLProtocol stub on Linux Foundation, so assert its content on Apple
            // only; the round-trip (below) is verified on both platforms.
            #if !canImport(FoundationNetworking)
                #expect(request.bodyData == sent)
            #endif
            return try (self.response(request, 201), Data())
        }
        let request = HTTPRequest(
            method: .post, scheme: "https", authority: "api.example.com", path: "/pay"
        )
        let (response, _) = try await URLSessionTransport(session: stubbedSession())
            .send(request, body: sent)
        #expect(response.status == .created)
    }

    @Test("a 402 response is returned verbatim (the transport applies no payment logic)")
    func passesThrough402() async throws {
        StubURLProtocol.respond { request in
            try (self.response(request, 402, ["WWW-Authenticate": "Payment realm=\"x\""]), Data())
        }
        let request = HTTPRequest(
            method: .get, scheme: "https", authority: "api.example.com", path: "/paid"
        )
        let (response, _) = try await URLSessionTransport(session: stubbedSession())
            .send(request, body: Data())
        #expect(response.status.code == 402)
        #expect(try response.headerFields[#require(.init("WWW-Authenticate"))]?
            .contains("Payment") == true)
    }

    @Test("does not follow redirects: a 30x surfaces to the caller (no credential downgrade)")
    func redirectsNotFollowed() async throws {
        StubURLProtocol.respond { request in
            // If followed, the credential would be carried to the redirect target.
            try (
                self.response(request, 302, ["Location": "http://api.example.com/elsewhere"]),
                Data()
            )
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(
            configuration: config, delegate: RedirectBlocker(), delegateQueue: nil
        )
        let request = HTTPRequest(
            method: .post, scheme: "https", authority: "api.example.com", path: "/start"
        )
        let (response, _) = try await URLSessionTransport(session: session)
            .send(request, body: Data("credential".utf8))
        #expect(response.status.code == 302)
    }

    // G7.5 parity (mpp-rs test_non_402_passthrough; mppx all-status-codes): a
    // non-2xx error response is returned verbatim, never thrown.
    @Test("non-2xx responses (404, 500) are returned verbatim without throwing")
    func nonSuccessPassthrough() async throws {
        for code in [404, 500] {
            StubURLProtocol.respond { request in
                try (self.response(request, code), Data("err-\(code)".utf8))
            }
            let request = HTTPRequest(
                method: .get, scheme: "https", authority: "api.example.com", path: "/x"
            )
            let (response, body) = try await URLSessionTransport(session: stubbedSession())
                .send(request, body: Data())
            #expect(response.status.code == code)
            #expect(body == Data("err-\(code)".utf8))
        }
    }

    @Test("an empty body uses the bodyless path and still round-trips")
    func emptyBodyRoundTrip() async throws {
        StubURLProtocol.respond { request in
            #expect(request.bodyData.isEmpty)
            return try (self.response(request, 204), Data())
        }
        let request = HTTPRequest(
            method: .post, scheme: "https", authority: "api.example.com", path: "/p"
        )
        let (response, _) = try await URLSessionTransport(session: stubbedSession())
            .send(request, body: Data())
        #expect(response.status.code == 204)
    }

    @Test("multiple request headers are all delivered")
    func multipleRequestHeaders() async throws {
        StubURLProtocol.respond { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Payment cred")
            #expect(request.value(forHTTPHeaderField: "Accept-Payment") == "tempo")
            #expect(request.value(forHTTPHeaderField: "X-Custom") == "v")
            return try (response(request, 200), Data())
        }
        var request = HTTPRequest(
            method: .get, scheme: "https", authority: "api.example.com", path: "/r"
        )
        try request.headerFields[#require(.init("Authorization"))] = "Payment cred"
        try request.headerFields[#require(.init("Accept-Payment"))] = "tempo"
        try request.headerFields[#require(.init("X-Custom"))] = "v"
        _ = try await URLSessionTransport(session: stubbedSession()).send(request, body: Data())
    }

    @Test("multiple response headers and a body map back together")
    func multipleResponseHeadersAndBody() async throws {
        StubURLProtocol.respond { request in
            try (
                self.response(
                    request,
                    200,
                    ["Content-Type": "application/json", "Payment-Receipt": "rcpt-1"]
                ),
                Data(#"{"paid":true}"#.utf8)
            )
        }
        let request = HTTPRequest(
            method: .get, scheme: "https", authority: "api.example.com", path: "/done"
        )
        let (response, body) = try await URLSessionTransport(session: stubbedSession())
            .send(request, body: Data())
        #expect(response.headerFields[.contentType] == "application/json")
        #expect(try response.headerFields[#require(.init("Payment-Receipt"))] == "rcpt-1")
        #expect(body == Data(#"{"paid":true}"#.utf8))
    }

    @Test("a network failure surfaces as a thrown error (not a value)")
    func networkFailureThrows() async {
        StubURLProtocol.respond { _ in throw URLError(.notConnectedToInternet) }
        let request = HTTPRequest(
            method: .get, scheme: "https", authority: "api.example.com", path: "/x"
        )
        await #expect(throws: (any Error).self) {
            _ = try await URLSessionTransport(session: self.stubbedSession())
                .send(request, body: Data())
        }
    }
}

/// A URLProtocol that returns a canned response from a per-test handler and reads
/// the request body for assertions. Not `final` so the overridden `class func`s
/// (required to override URLProtocol) are valid.
class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (
        @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    )?

    static func respond(
        _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        self.handler = handler
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler, let client else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        } catch {
            client.urlProtocol(self, didFailWithError: error)
        }
    }
}

extension URLRequest {
    /// The request body, read from `httpBody` or the upload `httpBodyStream`.
    var bodyData: Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
