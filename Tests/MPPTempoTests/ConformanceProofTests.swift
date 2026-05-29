import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// Cross-SDK conformance: drives the real client (PaymentClient + URLSessionTransport
// + TempoProofMethod) over real HTTP against a running mppx reference server, which
// issues a zero-amount `tempo`/`charge` 402 and verifies the proof credential. This
// is the alpha milestone: prove the wire works against a live mppx peer.
//
// Skipped unless `MPP_CONFORMANCE_URL` is set, so the default `swift test` and the
// pure-Swift CI never need Node or the network. Boot the server and run the whole
// thing with `Scripts/conformance/run.sh` (local mppx) or `--testnet` (Moderato).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MPP_CONFORMANCE_URL"] != nil))
struct ConformanceProofTests {
    @Test("pays an mppx zero-amount proof 402 end-to-end with the default v2 proof")
    func paysMppxProofChallenge() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["MPP_CONFORMANCE_URL"])
        let url = try #require(URL(string: raw))
        let scheme = try #require(url.scheme)
        let host = try #require(url.host(percentEncoded: false))
        let authority = url.port.map { "\(host):\($0)" } ?? host
        let path = url.path.isEmpty ? "/" : url.path

        // Any key works: a proof attests control of its own wallet. Fixed for
        // determinism (the key=1 wallet the rest of the suite uses).
        let signer = try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [1]))
        let method = try #require(TempoProofMethod(signer: signer))
        let client = PaymentClient(
            transport: URLSessionTransport(),
            methods: [method],
            allowInsecureLocal: true
        )

        let request = HTTPRequest(method: .get, scheme: scheme, authority: authority, path: path)
        let (response, body) = try await client.send(request)

        #expect(response.status.code == 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["paid"] as? Bool == true)
    }
}
