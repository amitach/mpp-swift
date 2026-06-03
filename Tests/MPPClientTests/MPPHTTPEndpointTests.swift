import Foundation
import MPPClient
import Testing

// The single home for deriving an HTTP `authority` and a redacted endpoint from a
// URL. The IPv6 cases are the reason it exists: an un-bracketed `::1` corrupts the
// authority (a bug a hand-rolled copy shipped before this was centralized).
@Suite("MPPHTTPEndpoint")
struct MPPHTTPEndpointTests {
    private func endpoint(_ string: String) throws -> MPPHTTPEndpoint {
        try MPPHTTPEndpoint(#require(URL(string: string)))
    }

    @Test("authority is host, or host:port, for a normal hostname")
    func authorityHostAndPort() throws {
        #expect(try endpoint("https://api.example.com/v1").authority == "api.example.com")
        #expect(try endpoint("https://api.example.com:8443/v1").authority == "api.example.com:8443")
    }

    @Test("authority brackets an IPv6 literal host (with and without a port)")
    func authorityBracketsIPv6() throws {
        #expect(try endpoint("http://[::1]/rpc").authority == "[::1]")
        #expect(try endpoint("http://[::1]:8545/rpc").authority == "[::1]:8545")
        #expect(try endpoint("http://[2001:db8::1]:80").authority == "[2001:db8::1]:80")
    }

    @Test("redactedEndpoint keeps only scheme + host, dropping any port, path, or query")
    func redactedEndpointStripsPathAndQuery() throws {
        #expect(try endpoint("https://rpc.example.com:8545/path?apiKey=secret").redactedEndpoint
            == "https://rpc.example.com")
    }
}
