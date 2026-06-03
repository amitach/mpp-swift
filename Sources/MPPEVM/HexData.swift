import Foundation

public extension Data {
    /// Parses a `0x`/`0X`-prefixed, even-length hex string into its bytes, or `nil`
    /// if the prefix is missing, the length is odd, or any non-hex character appears.
    ///
    /// The shared `0x`-hex decoder for the EVM layer: an Ethereum address, an
    /// EIP-712 signature, and other on-wire values all arrive as `0x`-prefixed hex.
    init?(hexPrefixed string: String) {
        let head = string.prefix(2)
        guard head == "0x" || head == "0X" else { return nil }
        let digits = Array(string.dropFirst(2))
        guard digits.count.isMultiple(of: 2) else { return nil }
        var raw = Data()
        raw.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = digits[index].hexDigitValue,
                  let low = digits[index + 1].hexDigitValue else { return nil }
            raw.append(UInt8(high << 4 | low))
            index += 2
        }
        self = raw
    }

    /// The bytes as a `0x`-prefixed lowercase hex string (the inverse of
    /// ``init(hexPrefixed:)``). The shared `0x`-hex encoder for the EVM layer:
    /// call data, raw transactions, and signatures all go on the wire this way.
    var hexPrefixed: String {
        "0x" + hexString
    }
}

extension Data {
    /// The bytes as a lowercase hex string with no prefix.
    ///
    /// Internal to MPPEVM: MPPCore ships the public cross-module `hexString`, and
    /// MPPEVM stays dependency-free of MPPCore, so each dependency island carries
    /// its own one-line encoder. Used by ``hexPrefixed`` and the EIP-55 checksum.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
