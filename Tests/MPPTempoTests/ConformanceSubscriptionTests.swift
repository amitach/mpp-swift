import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// Forward cross-SDK SUBSCRIPTION conformance: our Swift client (`PaymentClient` +
// `TempoSubscriptionMethod`) activates a subscription against the reference mppx
// subscription server. A PASS means our signed `TempoKeyAuthorization` (delegating
// the server-issued access key) was accepted by the reference verifier: the 402
// challenge our client parsed, the key authorization it signed, and the credential
// envelope it sent are all wire-compatible with mppx.
//
// Activation signs no on-chain transaction, so this is OFFLINE: no FFI, faucet, or
// RPC. Gated on MPP_CONFORMANCE_SUBSCRIPTION_URL (set by run-subscription.sh, which
// boots the mppx subscription server); skipped by the default `swift test`, so
// hermetic CI is unaffected.
private let subscriptionURL = ProcessInfo.processInfo
    .environment["MPP_CONFORMANCE_SUBSCRIPTION_URL"]

@Suite(.enabled(if: subscriptionURL != nil))
struct ConformanceSubscriptionTests {
    @Test("activate a subscription against the mppx server with a signed key authorization")
    func activationAgainstMppx() async throws {
        let raw = try #require(subscriptionURL)
        let url = try #require(URL(string: raw))
        let scheme = try #require(url.scheme)
        let host = try #require(url.host(percentEncoded: false))
        let authority = url.port.map { "\(host):\($0)" } ?? host
        let path = url.path.isEmpty ? "/" : url.path

        // Any root signer works: the server verifies the authorization recovers to the
        // credential's source, not a specific identity. The challenge carries chainId,
        // so the configured default is only a fallback.
        let signer = try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [1]))
        let method = try #require(TempoSubscriptionMethod(signer: signer))

        let recorder = CredentialBox()
        let client = PaymentClient(
            transport: URLSessionTransport(),
            methods: [method],
            allowInsecureLocal: true,
            onEvent: { event in
                if case let .credentialCreated(credential) = event { recorder.set(credential) }
            }
        )
        let request = HTTPRequest(method: .get, scheme: scheme, authority: authority, path: path)

        let (response, body) = try await client.send(request)
        // The reference server accepted our signed key authorization and activated.
        #expect(response.status.code == 200)
        let text = try #require(String(bytes: body, encoding: .utf8))
        #expect(text.contains("activated"))

        // The credential we sent was a key authorization (the subscription rail's shape).
        let credential = try #require(recorder.value)
        #expect(credential.payload["type"] == .string("keyAuthorization"))
        #expect(credential.payload["signature"] != nil)
    }
}

/// A Sendable box capturing the credential the client built (the flow's onEvent is
/// `@Sendable`).
private final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Credential?
    var value: Credential? {
        lock.withLock { stored }
    }

    func set(_ credential: Credential) {
        lock.withLock { stored = credential }
    }
}
