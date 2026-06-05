import Foundation
import Testing
@testable import MPPProxy

// PROXY-TLS: a ProxyService injects upstream credentials, so a non-loopback `http` origin (which
// would ship them in plaintext over a network) is rejected at construction. `https` is always
// allowed; a loopback `http` upstream is allowed only with the explicit `allowInsecureLocal`
// opt-in.
@Suite("ProxyService upstream TLS gate")
struct ProxyServiceTLSTests {
    private func service(
        _ urlString: String, allowInsecureLocal: Bool = false
    ) throws -> ProxyService {
        try ProxyService(
            id: "svc", baseURL: proxyURL(urlString), routes: [],
            allowInsecureLocal: allowInsecureLocal
        )
    }

    @Test("a non-loopback http upstream is rejected (PROXY-TLS)")
    func rejectsInsecureNonLoopback() {
        #expect(throws: ProxyService.ConfigurationError.self) {
            try service("http://api.example.com")
        }
    }

    @Test("the opt-in does not widen to a non-loopback http upstream")
    func optInDoesNotAllowNonLoopback() {
        #expect(throws: ProxyService.ConfigurationError.self) {
            try service("http://api.example.com", allowInsecureLocal: true)
        }
    }

    @Test("a loopback http upstream requires the explicit opt-in")
    func loopbackHttpRequiresOptIn() throws {
        #expect(throws: ProxyService.ConfigurationError.self) {
            try service("http://127.0.0.1:8080")
        }
        _ = try service("http://127.0.0.1:8080", allowInsecureLocal: true) // allowed with opt-in
    }

    @Test("an https upstream is always allowed")
    func httpsAlwaysAllowed() throws {
        _ = try service("https://api.example.com")
    }

    @Test("the bearer convenience init validates the upstream scheme too")
    func bearerInitValidates() {
        #expect(throws: ProxyService.ConfigurationError.self) {
            try ProxyService(
                id: "svc", baseURL: proxyURL("http://api.example.com"), routes: [],
                bearer: "secret-token"
            )
        }
    }

    @Test("the headers convenience init validates the upstream scheme too")
    func headersInitValidates() {
        #expect(throws: ProxyService.ConfigurationError.self) {
            try ProxyService(
                id: "svc", baseURL: proxyURL("http://api.example.com"), routes: [],
                headers: ["X-Api-Key": "secret"]
            )
        }
    }
}
