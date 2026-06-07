/// The x402 protocol version a bridge speaks. The two deployed versions differ in their HTTP
/// transport (header names + where the data lives), their PaymentRequirements field names
/// (`maxAmountRequired` vs `amount`), and their `network` encoding (a short name vs CAIP-2) -- but
/// not in the EIP-3009 `payload`. The SDK negotiates and translates both.
public enum X402Version: Int, Sendable, Hashable, Codable, CaseIterable {
    // `v1` / `v2` are x402's own version identifiers; the identifier_name 3-char minimum does not
    // fit them.
    // swiftlint:disable identifier_name
    /// x402 v1: the widely deployed version (`X-PAYMENT` / `X-PAYMENT-RESPONSE` headers, the 402
    /// body carries the requirements, short `network` names like `base-sepolia`).
    case v1 = 1
    /// x402 v2: the newer spec (`PAYMENT-REQUIRED` / `PAYMENT-SIGNATURE` / `PAYMENT-RESPONSE`
    /// headers, CAIP-2 `network` like `eip155:84532`).
    case v2 = 2
    // swiftlint:enable identifier_name
}

/// An EVM chain an x402 payment names, abstracting the version difference in how `network` is
/// written on the wire: x402 v2 uses CAIP-2 (`eip155:<chainId>`); x402 v1 uses a registered short
/// name (`base`, `base-sepolia`) and falls back to CAIP-2 for chains without one.
public struct X402Network: Sendable, Hashable {
    /// The EVM chain id.
    public let chainId: UInt64

    public init(chainId: UInt64) {
        self.chainId = chainId
    }

    /// Base mainnet.
    public static let base = X402Network(chainId: 8453)
    /// Base Sepolia testnet.
    public static let baseSepolia = X402Network(chainId: 84532)

    /// The x402 v1 short names, the one place the name <-> chain-id mapping lives.
    private static let shortNames: [String: UInt64] = ["base": 8453, "base-sepolia": 84532]

    /// The CAIP-2 identifier (`eip155:<chainId>`) -- the x402 v2 wire form.
    public var caip2: String {
        "eip155:\(chainId)"
    }

    /// The x402 v1 short name for this chain (`base`, `base-sepolia`), or `nil` if it has none.
    public var shortName: String? {
        Self.shortNames.first { $0.value == chainId }?.key
    }

    /// The on-wire `network` value for `version`: CAIP-2 for v2; the v1 short name for v1, falling
    /// back to CAIP-2 when the chain has no registered short name.
    public func wireValue(for version: X402Version) -> String {
        switch version {
        case .v2: caip2
        case .v1: shortName ?? caip2
        }
    }

    /// Parses an on-wire `network` value: CAIP-2 `eip155:<chainId>` or a v1 short name. Returns
    /// `nil` for an unrecognized form.
    public init?(wire: String) {
        let eip155 = "eip155:"
        if wire.hasPrefix(eip155), let id = UInt64(wire.dropFirst(eip155.count)) {
            self.init(chainId: id)
        } else if let id = Self.shortNames[wire] {
            self.init(chainId: id)
        } else {
            return nil
        }
    }
}
