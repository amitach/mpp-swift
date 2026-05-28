import Foundation
import MPPCore
import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §5.1.2.1.1:
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

    @Test("matches the known-answer id for every optional-slot shape")
    func knownAnswerVectors() throws {
        // Expected ids computed independently with openssl over the exact binding
        // input, secret 'test-secret-key-12345':
        //   printf '%s' '<bindingInput>' | openssl dgst -sha256 -hmac '<secret>' \
        //     -binary | openssl base64 | tr '+/' '-_' | tr -d '='
        let signer = signer()
        let method = try MethodName("tempo")
        let req = EncodedJSON("e30")
        let realm = "api.example.com"
        // (challenge, expected id): one case per slot that can vary the binding.
        let cases: [(Challenge, String)] = try [
            (
                Challenge(id: "x", realm: realm, method: method, intent: .charge, request: req),
                "r0Ljf4etU6bMy6evbN16GVjjo1UBSOtatsJ7ZkKeVlo"
            ), // required only
            (
                Challenge(
                    id: "x",
                    realm: realm,
                    method: method,
                    intent: .charge,
                    request: req,
                    expires: Expires("2025-01-06T12:00:00Z")
                ),
                "rOcsQP3bC4Me4geUeAxi0uTgpKKZ5271TsEG_vMTb08"
            ), // + expires
            (
                Challenge(
                    id: "x",
                    realm: realm,
                    method: method,
                    intent: .charge,
                    request: req,
                    digest: "sha-256=:X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE=:"
                ),
                "ThTdCGVn-JTBoV2M_xqBxud40ueTMrImCQbTY-Et8CI"
            ), // + digest (slot 6, expires empty)
            (
                Challenge(
                    id: "x",
                    realm: realm,
                    method: method,
                    intent: .charge,
                    request: req,
                    opaque: EncodedJSON("T3Bx")
                ),
                "VlW7gvFwGn1-zG62rqhzPdJEoiWE1VOxJSHKXtNlVMQ"
            ), // + opaque
            (
                Challenge(id: "x", realm: realm, method: method, intent: .session, request: req),
                "wdVGhT3h1woD3_D22rVvTAD4bxcwU40ZO5FI7_WoLcs"
            ), // different intent
        ]
        for (challenge, expected) in cases {
            #expect(signer.computeID(for: challenge) == expected)
        }
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
}
