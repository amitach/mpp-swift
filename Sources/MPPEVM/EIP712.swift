import Foundation

/// The minimal EIP-712 typed-data primitives the MPP proof credentials need: word
/// encoders for the field types that actually appear (`string`, `address`,
/// `uint256`), `hashStruct`, the `MPP` domain separator, and the final signing
/// hash. This is deliberately not a general typed-data engine: the MPP structs are
/// flat (no nested struct or array fields), so there is no recursive type
/// collection or dynamic `encodeType`. Each struct supplies its own fixed type
/// string and field words; this layer hashes them.
///
/// EIP-712 (`keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(message))`) is built on
/// `Keccak256` (the Ethereum hash), so it lives in `MPPEVM`, never in `MPPCore`.
public enum EIP712 {
    /// Encodes a dynamic `string` field: `keccak256(utf8Bytes)`.
    public static func string(_ value: String) -> Data {
        Keccak256.hash(Data(value.utf8))
    }

    /// Encodes a `uint256` field as a 32-byte big-endian word. Chain ids (and other
    /// values that fit in 64 bits) use this; the decimal-string `uint256` encoder
    /// for arbitrary amounts lands with its first consumer (the session voucher).
    public static func uint256(_ value: UInt64) -> Data {
        var word = Data(repeating: 0, count: 32)
        var remaining = value
        var offset = 31
        while remaining != 0 {
            word[offset] = UInt8(truncatingIfNeeded: remaining)
            remaining >>= 8
            offset -= 1
        }
        return word
    }

    /// Encodes a base-10 unsigned integer string as a 32-byte big-endian `uint256`
    /// word, or `nil` if `text` is empty, contains a non-ASCII-digit, or exceeds
    /// 2^256 - 1. This is the in-house amount encoder (the voucher's cumulative
    /// amount arrives as a decimal string); `UInt128`/`UInt256` are avoided because
    /// stdlib `UInt128` needs macOS 15 / iOS 18, above this package's deployment
    /// targets, and a big-integer dependency is unwarranted for plain encoding.
    public static func uint256(decimal text: String) -> Data? {
        guard !text.isEmpty else { return nil }
        var word = [UInt8](repeating: 0, count: 32)
        for character in text {
            guard ("0" ... "9").contains(character), let digit = character.wholeNumberValue else {
                return nil
            }
            var carry = digit
            var index = 31
            while index >= 0 {
                let value = Int(word[index]) * 10 + carry
                word[index] = UInt8(value & 0xFF)
                carry = value >> 8
                index -= 1
            }
            if carry != 0 { return nil } // overflowed 2^256
        }
        return Data(word)
    }

    /// `hashStruct(s) = keccak256(typeHash ‖ encodeData(s))`, where `encodeData` is
    /// the concatenation of the already-encoded 32-byte field words in declaration
    /// order.
    public static func hashStruct(typeHash: Data, fields: [Data]) -> Data {
        var encoded = typeHash
        for field in fields {
            encoded.append(field)
        }
        return Keccak256.hash(encoded)
    }

    /// The type hash of the MPP `EIP712Domain` (the proof domain carries only
    /// `name`, `version`, and `chainId`: no `verifyingContract`, no `salt`).
    public static let domainTypeHash: Data =
        Keccak256.hash(Data("EIP712Domain(string name,string version,uint256 chainId)".utf8))

    /// The domain separator for the MPP proof domain `(name, version, chainId)`.
    public static func domainSeparator(name: String, version: String, chainId: UInt64) -> Data {
        hashStruct(
            typeHash: domainTypeHash,
            fields: [string(name), string(version), uint256(chainId)]
        )
    }

    /// The type hash of the four-field `EIP712Domain` used by the session voucher,
    /// which additionally binds the escrow `verifyingContract`.
    public static let domainTypeHashWithVerifyingContract: Data = Keccak256.hash(Data(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8
    ))

    /// The domain separator for a domain that also binds a `verifyingContract`
    /// (the voucher's escrow contract).
    public static func domainSeparator(
        name: String, version: String, chainId: UInt64, verifyingContract: EthereumAddress
    ) -> Data {
        hashStruct(
            typeHash: domainTypeHashWithVerifyingContract,
            fields: [string(name), string(version), uint256(chainId), verifyingContract.word]
        )
    }

    /// The EIP-712 signing hash: `keccak256(0x19 0x01 ‖ domainSeparator ‖ structHash)`.
    /// This 32-byte digest is what `Secp256k1Signer` signs directly.
    public static func signingHash(domainSeparator: Data, structHash: Data) -> Data {
        var preimage = Data([0x19, 0x01])
        preimage.append(domainSeparator)
        preimage.append(structHash)
        return Keccak256.hash(preimage)
    }
}
