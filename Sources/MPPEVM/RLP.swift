import Foundation

/// Minimal RLP (Recursive Length Prefix, Ethereum's serialization) encoder and decoder.
///
/// RLP encodes two kinds of item: a byte string and a list of items. It is the wire format Tempo
/// uses for a ``TempoKeyAuthorization``. This is a small, self-contained implementation (the only
/// other RLP in the package is inside the Rust `0x76` transaction FFI, which is not reachable from
/// pure Swift); it covers exactly what the key-authorization serialization needs.
public enum RLP {
    /// An RLP item: a byte string, or a list of items.
    public indirect enum Item: Sendable, Hashable {
        case bytes(Data)
        case list([Item])
    }

    /// Encodes an item to its canonical RLP byte string.
    public static func encode(_ item: Item) -> Data {
        switch item {
        case let .bytes(value):
            if value.count == 1, value[value.startIndex] < 0x80 {
                return value
            }
            return encodeLength(value.count, offset: 0x80) + value
        case let .list(items):
            var payload = Data()
            for element in items {
                payload.append(encode(element))
            }
            return encodeLength(payload.count, offset: 0xC0) + payload
        }
    }

    /// A reason an RLP byte string could not be decoded.
    public enum DecodingError: Error, Sendable, Hashable {
        /// The input ended before a declared length was satisfied.
        case truncated
        /// A multi-byte length had a leading zero, more than 8 length bytes, or overflowed.
        case nonCanonicalLength
        /// Nested lists exceeded ``maxDepth`` (a stack-exhaustion guard on untrusted input).
        case tooDeep
        /// Bytes remained after the single top-level item was decoded.
        case trailingBytes
    }

    /// The maximum list-nesting depth accepted by ``decode(_:)``. RLP is decoded recursively, and a
    /// server decodes attacker-supplied credentials, so an unbounded depth would be a
    /// stack-exhaustion DoS. The key-authorization format nests ~5 deep; 64 is a generous ceiling.
    public static let maxDepth = 64

    /// Decodes a single top-level item from `data`, rejecting any trailing bytes.
    public static func decode(_ data: Data) throws(DecodingError) -> Item {
        let bytes = [UInt8](data)
        let (item, consumed) = try parse(bytes, at: 0, depth: 0)
        guard consumed == bytes.count else { throw .trailingBytes }
        return item
    }

    // MARK: - Encoding helpers

    /// The length prefix for a payload of `length` bytes: `offset+length` for short payloads
    /// (<= 55), otherwise `offset+55+byteCount` followed by the big-endian length.
    private static func encodeLength(_ length: Int, offset: UInt8) -> Data {
        if length <= 55 {
            return Data([offset + UInt8(length)])
        }
        let lengthBytes = bigEndian(length)
        return Data([offset + 55 + UInt8(lengthBytes.count)]) + lengthBytes
    }

    /// The minimal big-endian byte representation of a non-negative length.
    private static func bigEndian(_ value: Int) -> Data {
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data(bytes)
    }

    // MARK: - Decoding

    /// Parses one item starting at `index`, returning it and the number of bytes consumed.
    private static func parse(
        _ bytes: [UInt8],
        at index: Int,
        depth: Int
    ) throws(DecodingError) -> (Item, Int) {
        guard depth <= maxDepth else { throw .tooDeep }
        guard index < bytes.count else { throw .truncated }
        let prefix = bytes[index]

        if prefix <= 0x7F {
            return (.bytes(Data([prefix])), 1)
        }
        if prefix <= 0xB7 {
            let length = Int(prefix - 0x80)
            return try (.bytes(slice(bytes, from: index + 1, count: length)), 1 + length)
        }
        if prefix <= 0xBF {
            let (length, headerSize) = try readLength(bytes, at: index, base: 0xB7)
            let value = try slice(bytes, from: index + headerSize, count: length)
            return (.bytes(value), headerSize + length)
        }
        if prefix <= 0xF7 {
            let length = Int(prefix - 0xC0)
            return try (
                parseList(bytes, from: index + 1, payload: length, depth: depth),
                1 + length
            )
        }
        let (length, headerSize) = try readLength(bytes, at: index, base: 0xF7)
        return try (
            parseList(bytes, from: index + headerSize, payload: length, depth: depth),
            headerSize + length
        )
    }

    /// Reads a long-form length: `byteCount = prefix-base`, then that many big-endian length bytes.
    private static func readLength(
        _ bytes: [UInt8], at index: Int, base: UInt8
    ) throws(DecodingError) -> (length: Int, headerSize: Int) {
        // The prefix range caps a length-of-length at 8 bytes, so `length` accumulates at most 64
        // bits: an 8-byte value with its top bit set overflows `Int` into a negative number, which
        // the `length >= 0` guard below rejects as non-canonical.
        let byteCount = Int(bytes[index] - base)
        guard index + 1 + byteCount <= bytes.count else { throw .truncated }
        guard bytes[index + 1] != 0 else { throw .nonCanonicalLength }
        var length = 0
        for offset in 0 ..< byteCount {
            length = (length << 8) | Int(bytes[index + 1 + offset])
        }
        guard length >= 0 else { throw .nonCanonicalLength }
        return (length, 1 + byteCount)
    }

    /// Parses the items inside a list payload of `payload` bytes beginning at `start`.
    private static func parseList(
        _ bytes: [UInt8], from start: Int, payload: Int, depth: Int
    ) throws(DecodingError) -> Item {
        guard start + payload <= bytes.count else { throw .truncated }
        var items: [Item] = []
        var cursor = start
        let end = start + payload
        while cursor < end {
            let (item, consumed) = try parse(bytes, at: cursor, depth: depth + 1)
            items.append(item)
            cursor += consumed
        }
        return .list(items)
    }

    /// A bounds-checked slice of `count` bytes starting at `from`.
    private static func slice(
        _ bytes: [UInt8], from: Int, count: Int
    ) throws(DecodingError) -> Data {
        guard count >= 0, from + count <= bytes.count else { throw .truncated }
        return Data(bytes[from ..< (from + count)])
    }
}
