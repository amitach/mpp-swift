import Foundation

/// The `did:pkh:eip155` source DID that names the wallet (and chain) a zero-amount
/// proof is bound to: `did:pkh:eip155:{chainId}:{address}`, where the address is in
/// its EIP-55 checksummed form. A verifier reads this to know which address and
/// chain to check the proof signature against.
///
/// The format and the canonical parse (no leading zeros in the chain id, a
/// well-formed address) match both reference SDKs.
public enum ProofSource {
    private static let prefix = "did:pkh:eip155:"

    /// Builds the source DID for `(address, chainId)`, rendering the address in its
    /// EIP-55 checksummed form (the canonical representation).
    public static func did(address: EthereumAddress, chainId: UInt64) -> String {
        "\(prefix)\(chainId):\(address.checksummed)"
    }

    /// Parses a canonical `did:pkh:eip155:{chainId}:{address}` source DID, or returns
    /// `nil` if it is malformed: a missing prefix, an empty or leading-zero chain id
    /// (except the literal `0`), a non-numeric or out-of-range chain id, or an
    /// address that is not a `0x`-prefixed 40-hex string.
    public static func parse(_ source: String) -> (address: EthereumAddress, chainId: UInt64)? {
        guard source.hasPrefix(prefix) else { return nil }
        let rest = source.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let chainText = rest[rest.startIndex ..< colon]
        let addressText = String(rest[rest.index(after: colon)...])

        guard !chainText.isEmpty, chainText.allSatisfy({ ("0" ... "9").contains($0) }) else {
            return nil
        }
        if chainText.count > 1, chainText.first == "0" { return nil }
        guard let chainId = UInt64(chainText),
              let address = EthereumAddress(hex: addressText) else {
            return nil
        }
        return (address, chainId)
    }
}
