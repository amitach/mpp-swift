import MPPCore

/// Shared identity of the x402 charge method (the intent is `IntentName.charge`).
///
/// The MPP method id is **`exact`** -- the name of x402's EVM scheme (the same value the
/// credential's `type` carries). The literal token `"x402"` is *not* a usable id here:
/// `draft-httpauth-payment-00` Appendix A constrains a `payment-method-id` to `1*LOWERALPHA`
/// (lowercase letters, no digits), which `MethodName` enforces. The wire-level "x402" identity
/// (network, scheme, `x402Version`) lives in the bridge's PaymentRequirements, not the MPP method
/// name. Built once here and reused by the client (``X402ChargeMethod``) and the server verifier.
public enum X402Method {
    /// The canonical method name -- the x402 `exact` scheme.
    public static let name: MethodName = {
        guard let name = try? MethodName("exact") else {
            preconditionFailure("exact is a valid method name")
        }
        return name
    }()
}

/// The EVM chains the x402-on-Base rail targets.
public enum X402Chain {
    /// Base mainnet.
    public static let baseMainnet: UInt64 = 8453
    /// Base Sepolia testnet.
    public static let baseSepolia: UInt64 = 84532
}
