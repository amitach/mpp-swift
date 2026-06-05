import Foundation
import MPPEVM
import Testing

// SIG-1-test (audit pin): secp256k1 signature identity is by the RECOVERED ADDRESS, not the raw
// signature bytes. We do not reject a high-s signature (the EIP-2 malleability twin): the malleated
// signature (s' = n - s with the recovery bit flipped) recovers the SAME address as the original,
// so it authorizes identically. This matches the mppx peer (SIG-1 is documented, not rejected --
// identity is the recovered address, so accepting the twin grants nothing a forger couldn't already
// do by re-presenting the original).
@Suite("secp256k1 high-s malleability (SIG-1)")
struct Secp256k1MalleabilityTests {
    // The secp256k1 group order n, big-endian.
    private static let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    ]

    /// `n - scalar` for a 32-byte big-endian value (with `scalar < n`, which a valid signature's
    /// `s` always is).
    private static func complement(_ scalar: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            let diff = Int(order[index]) - Int(scalar[index]) - borrow
            result[index] = UInt8((diff + 256) % 256)
            borrow = diff < 0 ? 1 : 0
        }
        return result
    }

    @Test("the high-s malleability twin recovers the same address (SIG-1)")
    func highSTwinRecoversSameAddress() throws {
        let hash = Data([UInt8](repeating: 0x42, count: 32))
        let wire = try [UInt8](key1Signer().sign(hash: hash).ethereumWire) // r || s || v, low-s

        // Sanity: the original (low-s) signature recovers the signer's address.
        #expect(EthereumAddress.recover(hash: hash, signature: Data(wire)) == key1Address)

        // Build the malleability twin: s' = n - s (high-s), recovery bit flipped (27 <-> 28).
        let rBytes = Array(wire[0 ..< 32])
        let sBytes = Array(wire[32 ..< 64])
        let twinS = Self.complement(sBytes)
        let twinV: UInt8 = wire[64] == 27 ? 28 : 27
        let twin = Data(rBytes + twinS + [twinV])

        #expect(twinS != sBytes) // it is genuinely a different signature
        // The high-s twin is NOT rejected and recovers the SAME identity as the original.
        #expect(EthereumAddress.recover(hash: hash, signature: twin) == key1Address)
    }
}
