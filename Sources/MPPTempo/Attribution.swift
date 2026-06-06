import Foundation
import MPPEVM

/// The MPP attribution memo carried by the TIP-20 `transferWithMemo` of a recurring
/// subscription charge: a 32-byte value that marks the transfer as an MPP payment on-chain
/// and binds it to the challenge it settles. When a charge carries no user-provided memo,
/// the server auto-generates this so MPP transactions are identifiable (filterable by the
/// `TransferWithMemo` event).
///
/// Wire layout (the Tempo attribution memo format; the reference SDK emits the identical
/// bytes for the same inputs, proven by the pinned vectors in the tests):
///
/// | bytes  | width | field                                                  |
/// |--------|-------|--------------------------------------------------------|
/// | 0..3   | 4     | `tag` = `keccak256("mpp")[0..3]`                       |
/// | 4      | 1     | `version` (`0x01`)                                     |
/// | 5..14  | 10    | server fingerprint = `keccak256(serverId)[0..9]`       |
/// | 15..24 | 10    | client fingerprint = `keccak256(clientId)[0..9]`, or 0 |
/// | 25..31 | 7     | nonce = `keccak256(challengeId)[0..6]` (binds the memo) |
public enum Attribution {
    /// The on-chain MPP tag: the first 4 bytes of `keccak256("mpp")`.
    public static let tag: Data = Keccak256.hash(Data("mpp".utf8)).prefix(4)

    /// The current memo version byte.
    public static let version: UInt8 = 0x01

    /// The 32-byte attribution memo for a charge.
    ///
    /// - Parameters:
    ///   - serverId: the server identity; its fingerprint occupies bytes 5..14.
    ///   - challengeId: the challenge id; its nonce (bytes 25..31) binds the memo to the
    ///     challenge so a transaction hash cannot be reused across challenges.
    ///   - clientId: an optional client identity (bytes 15..24); 10 zero bytes when absent.
    public static func encode(
        serverId: String,
        challengeId: String,
        clientId: String? = nil
    ) -> Data {
        var memo = Data(repeating: 0, count: 32)
        memo.replaceSubrange(0 ..< 4, with: tag)
        memo[4] = version
        memo.replaceSubrange(5 ..< 15, with: fingerprint(serverId))
        if let clientId {
            memo.replaceSubrange(15 ..< 25, with: fingerprint(clientId))
        }
        memo.replaceSubrange(25 ..< 32, with: Keccak256.hash(Data(challengeId.utf8)).prefix(7))
        return memo
    }

    /// Whether `memo` is an MPP attribution memo bound to `serverId` and `challengeId`: the `tag`,
    /// `version`, server fingerprint (bytes 5..14), and challenge nonce (bytes 25..31) must all
    /// match. The **client fingerprint (bytes 15..24) is deliberately not checked** -- the server
    /// does not pin the client identity, so a verifier accepts a memo from any client. Used by the
    /// settled-charge verifier to confirm an auto-generated memo settled for *this* challenge, so
    /// an
    /// on-chain transfer's hash cannot be reused to satisfy a different challenge.
    public static func matches(memo: Data, serverId: String, challengeId: String) -> Bool {
        let bytes = Data(memo) // normalize a possible slice to 0-based indices
        guard bytes.count == 32 else { return false }
        return bytes[0 ..< 4] == tag
            && bytes[4] == version
            && bytes[5 ..< 15] == fingerprint(serverId)
            && bytes[25 ..< 32] == Keccak256.hash(Data(challengeId.utf8)).prefix(7)
    }

    /// A 10-byte fingerprint of `value`: `keccak256(value)[0..9]`.
    private static func fingerprint(_ value: String) -> Data {
        Keccak256.hash(Data(value.utf8)).prefix(10)
    }
}
