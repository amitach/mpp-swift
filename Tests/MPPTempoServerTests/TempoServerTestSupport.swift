import Foundation
import MPPEVM

// Shared fixtures for the MPPTempoServer test target (one home, not per-file copies).
// The key->signer helper lives in TempoProofVerifierTests (`signer(byte:)`, internal).

/// Builds an ``EthereumAddress`` from a hex string, trapping on invalid input.
func tempoTestAddress(_ hex: String) -> EthereumAddress {
    guard let address = EthereumAddress(hex: hex) else {
        preconditionFailure("invalid test address \(hex)")
    }
    return address
}
