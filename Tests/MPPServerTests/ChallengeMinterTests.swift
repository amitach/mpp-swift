import Foundation
import MPPCore
import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §5.1 / §5.1.2.1.1. The minter composes a
// Challenge for a route and stamps
// id = base64url(HMAC-SHA256(secret, bindingInput)).
@Suite("ChallengeMinter")
struct ChallengeMinterTests {
    private func makeMinter() -> ChallengeMinter {
        ChallengeMinter(signer: ChallengeSigner(secret: secret))
    }

    private func makeSigner() -> ChallengeSigner {
        ChallengeSigner(secret: secret)
    }

    @Test("a minted challenge carries the route's realm, method, and intent")
    func mintsBoundFields() throws {
        let route = try makeBinding()
        let challenge = makeMinter().mint(binding: route, request: EncodedJSON("e30"))
        #expect(challenge.realm == route.realm)
        #expect(challenge.method == route.method)
        #expect(challenge.intent == route.intent)
        #expect(route.matches(challenge))
    }

    @Test("a minted challenge's id verifies under the same signer's secret")
    func mintedIDVerifies() throws {
        let challenge = try makeMinter().mint(binding: makeBinding(), request: EncodedJSON("e30"))
        #expect(makeSigner().verify(challenge))
    }

    @Test("a minted challenge round-trips through its WWW-Authenticate header value")
    func roundTripsThroughHeader() throws {
        let challenge = try makeMinter().mint(
            binding: makeBinding(),
            request: EncodedJSON("e30"),
            expires: Expires("2027-01-01T00:00:00Z"),
            opaque: EncodedJSON("eyJrIjoxfQ")
        )
        let reparsed = try Challenge(headerValue: challenge.headerValue)
        #expect(reparsed == challenge)
        #expect(makeSigner().verify(reparsed))
    }

    @Test("the id changes when any bound field changes")
    func idBindsEveryBoundSlot() throws {
        let route = try makeBinding()
        let minter = makeMinter()
        let base = minter.mint(binding: route, request: EncodedJSON("e30"))
        // A different request slot must yield a different id.
        let otherRequest = minter.mint(binding: route, request: EncodedJSON("eyJhIjoxfQ"))
        #expect(otherRequest.id != base.id)
        // Adding an expiry (a bound optional slot) must yield a different id.
        let withExpiry = try minter.mint(
            binding: route,
            request: EncodedJSON("e30"),
            expires: Expires("2027-01-01T00:00:00Z")
        )
        #expect(withExpiry.id != base.id)
        // Adding a digest (a bound optional slot) must yield a different id.
        let withDigest = minter.mint(
            binding: route, request: EncodedJSON("e30"), digest: "sha-256=:abc:"
        )
        #expect(withDigest.id != base.id)
        #expect(makeSigner().verify(withDigest))
        // Adding opaque (a bound optional slot) must yield a different id.
        let withOpaque = minter.mint(
            binding: route, request: EncodedJSON("e30"), opaque: EncodedJSON("eyJrIjoxfQ")
        )
        #expect(withOpaque.id != base.id)
        #expect(makeSigner().verify(withOpaque))
        // A different realm/method/intent must yield a different id.
        let otherRoute = try RouteBinding(
            realm: "other.example.com", method: MethodName("tempo"), intent: .charge
        )
        #expect(minter.mint(binding: otherRoute, request: EncodedJSON("e30")).id != base.id)
    }

    @Test("description is carried but not bound (display-only)")
    func descriptionNotBound() throws {
        let route = try makeBinding()
        let minter = makeMinter()
        let plain = minter.mint(binding: route, request: EncodedJSON("e30"))
        let described = minter.mint(
            binding: route, request: EncodedJSON("e30"), description: "Pay 0.10 to read"
        )
        #expect(described.description == "Pay 0.10 to read")
        // description is not part of bindingInput, so the id is unchanged.
        #expect(described.id == plain.id)
    }
}
