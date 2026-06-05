import Foundation
import MPPCore

/// A fixed expiry instant (2026-01-02T00:00:00Z) for deterministic page output.
let fixedExpiry = Date(timeIntervalSince1970: 1_767_312_000)

/// Builds a challenge for the renderer tests. Defaults to a realm, method, and
/// intent the page can display; pass `expires`/`description` to drive those rows.
func makeChallenge(
    id: String = "chal-123",
    realm: String = "https://api.example.com",
    method: String = "tempo",
    expires: Expires? = Expires(date: fixedExpiry),
    description: String? = nil
) throws -> Challenge {
    try Challenge(
        id: id,
        realm: realm,
        method: MethodName(method),
        intent: .charge,
        request: EncodedJSON("e30"),
        digest: nil,
        expires: expires,
        description: description
    )
}

/// The number of non-overlapping occurrences of `needle` in `haystack`.
func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}
