import Foundation
import MPPClient
import Testing

// TLS-TABLE (audit pin): the shared transport-security policy. `https` is always allowed; plain
// `http` only to a recognized loopback host under `allowInsecureLocal`. The loopback table is
// deliberately narrow (exact `localhost`/`127.0.0.1`/`::1` and the RFC 6761 `.localhost` suffix),
// so look-alikes (`localhost.attacker.com`, `::ffff:127.0.0.1`, `127.0.0.2`) are NOT loopback and
// never get the plaintext exception.
@Suite("TransportSecurity (TLS-TABLE)")
struct TransportSecurityTests {
    @Test("https is allowed regardless of host or the local opt-in")
    func httpsAlwaysAllowed() {
        #expect(TransportSecurity.isAllowed(
            scheme: "https", host: "api.example.com", allowInsecureLocal: false
        ))
        #expect(TransportSecurity.isAllowed(scheme: "HTTPS", host: nil, allowInsecureLocal: false))
    }

    @Test("plain http is rejected without the local opt-in, even for loopback")
    func httpRejectedWithoutOptIn() {
        #expect(!TransportSecurity.isAllowed(
            scheme: "http", host: "127.0.0.1", allowInsecureLocal: false
        ))
        #expect(!TransportSecurity.isAllowed(
            scheme: "http", host: "localhost", allowInsecureLocal: false
        ))
    }

    @Test("the recognized loopback hosts (and only those)")
    func loopbackTable() {
        // Allowed: exact loopback names/addresses and the RFC 6761 .localhost suffix (any case).
        let loopback = [
            "localhost",
            "LOCALHOST",
            "127.0.0.1",
            "::1",
            "api.localhost",
            "x.y.localhost",
        ]
        for host in loopback {
            #expect(TransportSecurity.isLoopback(host), "expected loopback: \(host)")
        }
        // Denied look-alikes -- the security-relevant half of the table.
        for host in [
            "localhost.attacker.com", // suffix attack: ends in .com, not .localhost
            "127.0.0.1.attacker.com",
            "::ffff:127.0.0.1", // IPv4-mapped IPv6, not ::1
            "127.0.0.2", // loopback /8 not honored; only 127.0.0.1
            "10.0.0.1",
            "169.254.169.254", // link-local metadata endpoint
            "example.com",
            "localhostx",
            "",
        ] {
            #expect(!TransportSecurity.isLoopback(host), "expected NOT loopback: \(host)")
        }
    }

    @Test("a loopback http host is allowed only under the explicit opt-in")
    func loopbackHttpUnderOptIn() {
        #expect(TransportSecurity.isAllowed(
            scheme: "http", host: "127.0.0.1", allowInsecureLocal: true
        ))
        // The opt-in does not extend to a non-loopback http host.
        #expect(!TransportSecurity.isAllowed(
            scheme: "http", host: "localhost.attacker.com", allowInsecureLocal: true
        ))
    }
}
