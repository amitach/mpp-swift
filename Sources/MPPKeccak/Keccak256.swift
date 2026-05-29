import Foundation

/// Keccak-256, the Ethereum hash (**not** NIST SHA3-256; the padding differs:
/// Keccak appends `0x01`, SHA-3 appends `0x06`).
///
/// A clean-room implementation of the standard Keccak-f[1600] sponge: rate 1088
/// bits (136 bytes), capacity 512, original multi-rate `pad10*1` padding, 256-bit
/// output. swift-crypto ships no Keccak and NIST SHA-3 is the wrong function, so
/// rather than pull a third-party package this is implemented here where every
/// line is auditable, and its correctness is proven by official known-answer
/// vectors that exercise the rate boundary (135/136/137 bytes) and multi-block
/// inputs (see `Keccak256Tests`). The algorithm is the fully-specified Keccak
/// permutation; it is not an ad-hoc construction.
public enum Keccak256 {
    /// The 32-byte Keccak-256 digest of `input`.
    public static func hash(_ input: Data) -> Data {
        let rate = 136
        var state = [UInt64](repeating: 0, count: 25)

        // pad10*1 (original Keccak): append 0x01, zero-fill to a rate multiple,
        // set the final byte's high bit. When only one pad byte is free it holds
        // both bits (0x01 | 0x80 = 0x81); a full final block adds another block.
        var message = [UInt8](input)
        message.append(0x01)
        while message.count % rate != 0 {
            message.append(0)
        }
        message[message.count - 1] |= 0x80

        // Absorb: XOR each rate-sized block (little-endian lanes) into the state,
        // then permute.
        var offset = 0
        while offset < message.count {
            for lane in 0 ..< (rate / 8) {
                var value: UInt64 = 0
                for byte in 0 ..< 8 {
                    value |= UInt64(message[offset + lane * 8 + byte]) << (8 * byte)
                }
                state[lane] ^= value
            }
            permute(&state)
            offset += rate
        }

        // Squeeze 256 bits (the first four lanes; 32 < rate, so one squeeze).
        var output = [UInt8]()
        output.reserveCapacity(32)
        for lane in 0 ..< 4 {
            let value = state[lane]
            for byte in 0 ..< 8 {
                output.append(UInt8((value >> (8 * byte)) & 0xFF))
            }
        }
        return Data(output)
    }

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]

    /// Lane rotation offsets along the rho/pi path.
    private static let rotations: [Int] = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
    ]

    /// Destination lane indices for the pi permutation.
    private static let piLanes: [Int] = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
    ]

    private static func rotl(_ value: UInt64, _ count: Int) -> UInt64 {
        (value << count) | (value >> (64 - count))
    }

    /// The Keccak-f[1600] permutation: 24 rounds of theta, rho+pi, chi, iota on
    /// the 5x5 lane state indexed `a[x + 5*y]`.
    private static func permute(_ lanes: inout [UInt64]) {
        for round in 0 ..< 24 {
            // theta
            var parity = [UInt64](repeating: 0, count: 5)
            for column in 0 ..< 5 {
                parity[column] = lanes[column] ^ lanes[column + 5] ^ lanes[column + 10]
                    ^ lanes[column + 15] ^ lanes[column + 20]
            }
            for column in 0 ..< 5 {
                let delta = parity[(column + 4) % 5] ^ rotl(parity[(column + 1) % 5], 1)
                for row in 0 ..< 5 {
                    lanes[column + 5 * row] ^= delta
                }
            }
            // rho + pi
            var last = lanes[1]
            for index in 0 ..< 24 {
                let target = piLanes[index]
                let temp = lanes[target]
                lanes[target] = rotl(last, rotations[index])
                last = temp
            }
            // chi
            for row in 0 ..< 5 {
                let rowLanes = (0 ..< 5).map { lanes[$0 + 5 * row] }
                for column in 0 ..< 5 {
                    lanes[column + 5 * row] = rowLanes[column]
                        ^ (~rowLanes[(column + 1) % 5] & rowLanes[(column + 2) % 5])
                }
            }
            // iota
            lanes[0] ^= roundConstants[round]
        }
    }
}
