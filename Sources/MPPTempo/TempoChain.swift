/// The Tempo network chain ids, as named constants.
///
/// A Tempo charge challenge may carry its `chainId` in `methodDetails`; when it
/// does not, the method falls back to a configured chain, defaulting to Tempo
/// mainnet (the same fallback the reference SDKs apply). These are the canonical
/// ids a caller picks from when overriding that default, named rather than passed
/// as bare integers.
public enum TempoChain {
    /// Tempo mainnet (`4217`).
    public static let mainnet: UInt64 = 4217
    /// Tempo Moderato testnet (`42431`).
    public static let moderatoTestnet: UInt64 = 42431
}
