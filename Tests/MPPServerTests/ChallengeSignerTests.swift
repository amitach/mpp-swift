import Crypto
import Foundation
import MPPCore
import Testing
@testable import MPPServer

// Spec: draft-httpauth-payment-00 §5.1.2.1.1 —
// id = base64url(HMAC-SHA256(secret, bindingInput)), unpadded.
@Suite("ChallengeSigner")
struct ChallengeSignerTests {
    private let secret = Data("test-secret-key-12345".utf8)

    private func signer() -> ChallengeSigner {
        ChallengeSigner(secret: secret)
    }

    /// A challenge with no optionals; its bindingInput is
    /// `api.example.com|tempo|charge|e30|||`.
    private func draft(id: String = "unsigned") throws -> Challenge {
        try Challenge(
            id: id, realm: "api.example.com", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("e30")
        )
    }

    /// Returns `challenge` with its id replaced by this signer's HMAC.
    private func sign(_ challenge: Challenge, with signer: ChallengeSigner) -> Challenge {
        Challenge(
            id: signer.computeID(for: challenge),
            realm: challenge.realm, method: challenge.method, intent: challenge.intent,
            request: challenge.request, digest: challenge.digest, expires: challenge.expires,
            description: challenge.description, opaque: challenge.opaque
        )
    }

    @Test("computes the openssl-derived golden id over the binding input")
    func computesGoldenID() throws {
        // Independently computed:
        //   printf '%s' 'api.example.com|tempo|charge|e30|||' \
        //     | openssl dgst -sha256 -hmac 'test-secret-key-12345' -binary \
        //     | openssl base64 | tr '+/' '-_' | tr -d '='
        #expect(try signer()
            .computeID(for: draft()) == "r0Ljf4etU6bMy6evbN16GVjjo1UBSOtatsJ7ZkKeVlo")
    }

    @Test("the id is unpadded base64url")
    func idIsUnpaddedBase64URL() throws {
        let id = try signer().computeID(for: draft())
        #expect(!id.contains("="))
        #expect(!id.contains("+"))
        #expect(!id.contains("/"))
    }

    @Test("verifies a challenge it signed")
    func verifiesSigned() throws {
        let signed = try sign(draft(), with: signer())
        #expect(signer().verify(signed))
    }

    @Test("computeID ignores the challenge's own id (it is not in the binding input)")
    func computeIgnoresOwnID() throws {
        let signer = signer()
        #expect(try signer.computeID(for: draft(id: "a")) == signer.computeID(for: draft(id: "b")))
    }

    @Test("rejects a challenge whose bound field was tampered after signing")
    func rejectsTamper() throws {
        let signed = try sign(draft(), with: signer())
        // Same id, but the realm (a bound slot) changed: the recomputed MAC differs.
        let tampered = Challenge(
            id: signed.id, realm: "evil.example.com", method: signed.method,
            intent: signed.intent, request: signed.request
        )
        #expect(!signer().verify(tampered))
    }

    @Test("rejects a challenge signed under a different secret")
    func rejectsWrongSecret() throws {
        let signed = try sign(draft(), with: ChallengeSigner(secret: Data("other-secret".utf8)))
        #expect(!signer().verify(signed))
    }

    @Test("rejects an id that is not valid unpadded base64url")
    func rejectsMalformedID() throws {
        let bad = try draft(id: "not valid base64url!!")
        #expect(!signer().verify(bad))
    }

    @Test("binds every optional slot: adding expires changes the id and re-verifies")
    func bindsOptionalSlots() throws {
        let signer = signer()
        let base = try sign(draft(), with: signer)
        let withExpires = try sign(
            Challenge(
                id: "x", realm: "api.example.com", method: MethodName("tempo"),
                intent: .charge, request: EncodedJSON("e30"),
                expires: Expires("2026-01-01T00:00:00Z")
            ),
            with: signer
        )
        #expect(base.id != withExpires.id)
        #expect(signer.verify(withExpires))
    }
}
