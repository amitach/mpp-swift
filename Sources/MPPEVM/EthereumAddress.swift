import Foundation

/// A 20-byte Ethereum account address.
///
/// Used as the `address wallet` field of the v1 zero-amount proof and as the
/// subject of a `did:pkh:eip155` proof source. Stored as exactly 20 raw bytes;
/// the EIP-712 word encoding (left-padded to 32 bytes) and the EIP-55 checksummed
/// hex string are derived from those bytes.
public struct EthereumAddress: Sendable, Hashable {
    /// The 20 raw address bytes.
    public let bytes: Data

    /// Wraps exactly 20 bytes, or `nil` if `bytes` is not 20 bytes long.
    public init?(bytes: Data) {
        guard bytes.count == 20 else { return nil }
        self.bytes = bytes
    }

    /// Parses a `0x`-prefixed, 40-character hex string (case-insensitive). Returns
    /// `nil` for any other length, a missing prefix, or a non-hex character. EIP-55
    /// checksum casing is accepted but not required or verified here (the address is
    /// defined by its bytes; casing is a display concern).
    public init?(hex: String) {
        guard hex.count == 42, hex.hasPrefix("0x") || hex.hasPrefix("0X") else { return nil }
        var raw = Data()
        raw.reserveCapacity(20)
        let digits = Array(hex.dropFirst(2))
        var index = 0
        while index < digits.count {
            guard let high = digits[index].hexDigitValue,
                  let low = digits[index + 1].hexDigitValue else { return nil }
            raw.append(UInt8(high << 4 | low))
            index += 2
        }
        bytes = raw
    }

    /// Derives the address from a 65-byte uncompressed secp256k1 public key
    /// (`0x04 ‖ X ‖ Y`): the low 20 bytes of `keccak256(X ‖ Y)`. Returns `nil` only
    /// if the key is malformed; for a key from ``Secp256k1Signer`` it always succeeds.
    public init?(uncompressedPublicKey key: Data) {
        guard key.count == 65, key.first == 0x04 else { return nil }
        // keccak256 is 32 bytes, so its low 20 bytes are always a valid address.
        bytes = Data(Keccak256.hash(Data(key.dropFirst())).suffix(20))
    }

    /// The 32-byte EIP-712 word: 12 zero bytes followed by the 20 address bytes.
    public var word: Data {
        Data(repeating: 0, count: 12) + bytes
    }

    /// The EIP-55 checksummed `0x`-prefixed hex form: a hex nibble is uppercased
    /// when the corresponding nibble of `keccak256(lowercase-hex-without-0x)` is
    /// >= 8. This is the canonical address rendering used in a `did:pkh` source.
    public var checksummed: String {
        let lower = bytes.map { String(format: "%02x", $0) }.joined()
        let hashHex = Keccak256.hash(Data(lower.utf8)).map { String(format: "%02x", $0) }.joined()
        var out = "0x"
        for (character, hashNibble) in zip(lower, hashHex) {
            if character.isLetter, let value = hashNibble.hexDigitValue, value >= 8 {
                out.append(Character(character.uppercased()))
            } else {
                out.append(character)
            }
        }
        return out
    }
}
