import Foundation
import MPPEVM

// Shared helpers for the MPPEVM test target, consolidated from per-file copies so
// the same primitive is defined once. Internal (target-scoped), so every test file
// in MPPEVMTests sees these without redeclaring them.

/// Builds an ``EthereumAddress`` from a hex string, trapping on invalid input.
func testAddress(_ hex: String) -> EthereumAddress {
    guard let address = EthereumAddress(hex: hex) else {
        preconditionFailure("invalid test address \(hex)")
    }
    return address
}

/// Decodes an unprefixed hex string into `Data`, trapping on invalid input.
func hexData(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index ..< next], radix: 16) else {
            preconditionFailure("invalid test hex \(hex)")
        }
        data.append(byte)
        index = next
    }
    return data
}

/// Lowercase hex encoding of `data`.
func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// The canonical test private key: secp256k1 key = 1.
let key1PrivateKey = Data([UInt8](repeating: 0, count: 31) + [1])

/// The address of ``key1PrivateKey`` (secp256k1 key = 1).
let key1Address = testAddress("0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")

/// A signer for ``key1PrivateKey``.
func key1Signer() throws -> Secp256k1Signer {
    try Secp256k1Signer(privateKey: key1PrivateKey)
}
