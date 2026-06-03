import Foundation

public extension Sequence<UInt8> {
    /// The bytes as a lowercase hex string with no prefix.
    ///
    /// The canonical lowercase-hex encoder for the MPPCore layer and up: a
    /// replay-store filename and a Stripe idempotency key render a `SHA256Digest`,
    /// a session receipt renders a `0x`-prefixed channel id via `"0x" + hexString`.
    /// Defined on `Sequence<UInt8>` so it covers `Data`, a crypto `Digest`, and a
    /// raw byte array uniformly. (MPPEVM is dependency-free of MPPCore and keeps an
    /// internal copy for its `0x`-hex encoder.)
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
