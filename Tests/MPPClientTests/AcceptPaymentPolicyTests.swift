import Foundation
import MPPClient
import Testing

// Gate for the Accept-Payment header. Origins compared per RFC 6454
// (scheme, host, effective port); *.host is a subdomain wildcard that also
// matches the bare host. Mirrors both reference SDKs' policy semantics.
@Suite("AcceptPaymentPolicy")
struct AcceptPaymentPolicyTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test("always allows everything; never allows nothing")
    func alwaysAndNever() throws {
        #expect(try AcceptPaymentPolicy.always.allows(url("https://api.example.com/x")))
        #expect(try AcceptPaymentPolicy.always.allows(url("http://localhost:8080/x")))
        #expect(try !AcceptPaymentPolicy.never.allows(url("https://api.example.com/x")))
    }

    @Test(
        "sameOrigin matches on scheme + host + effective port, including default-port normalization"
    )
    func sameOrigin() throws {
        let policy = try AcceptPaymentPolicy.sameOrigin(url("https://api.example.com"))
        // Same origin, different path/explicit default port.
        #expect(try policy.allows(url("https://api.example.com/pay")))
        #expect(try policy.allows(url("https://api.example.com:443/pay"))) // 443 == https default
        // Differing scheme, host, or non-default port are different origins.
        #expect(try !policy.allows(url("http://api.example.com/pay"))) // scheme
        #expect(try !policy.allows(url("https://other.example.com/pay"))) // host
        #expect(try !policy.allows(url("https://api.example.com:8443/pay"))) // port
    }

    @Test("origins matches exact origins and *.host wildcards (including the bare host)")
    func origins() throws {
        let policy = AcceptPaymentPolicy.origins([
            "https://exact.example.com",
            "*.wild.example.com",
        ])
        // Exact origin.
        #expect(try policy.allows(url("https://exact.example.com/r")))
        #expect(try !policy.allows(url("https://exact.example.com:9000/r"))) // port differs
        #expect(try !policy.allows(url("http://exact.example.com/r"))) // scheme differs
        // Wildcard: bare host, a subdomain, and a deep subdomain match; a sibling does not.
        #expect(try policy.allows(url("https://wild.example.com/r")))
        #expect(try policy.allows(url("https://a.wild.example.com/r")))
        #expect(try policy
            .allows(url("http://a.b.wild.example.com/r"))) // wildcard ignores scheme/port
        #expect(try !policy.allows(url("https://wild.example.org/r")))
        #expect(try !policy.allows(url("https://notwild.example.com/r")))
    }

    @Test(
        "an exact-origin pattern normalizes its default port; a bare host-only pattern is rejected"
    )
    func originPatternEdges() throws {
        // The pattern's explicit default port equals the request's implicit one.
        let withPort = AcceptPaymentPolicy.origins(["https://example.com:443"])
        #expect(try withPort.allows(url("https://example.com/r")))
        // A host without a scheme is neither an exact origin nor a *.wildcard: rejected.
        let hostOnly = AcceptPaymentPolicy.origins(["api.example.com"])
        #expect(try !hostOnly.allows(url("https://api.example.com/r")))
    }

    @Test("a URL without a host or scheme is not advertised to (except under always)")
    func malformedOrigin() throws {
        let policy = try AcceptPaymentPolicy.sameOrigin(url("https://api.example.com"))
        let schemeless = try url("//api.example.com/x") // no scheme
        #expect(!policy.allows(schemeless))
        #expect(AcceptPaymentPolicy.always.allows(schemeless))
    }
}
