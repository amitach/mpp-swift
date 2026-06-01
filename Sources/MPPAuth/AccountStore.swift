import Foundation

/// A named store of payer private keys: the CLI's `account` commands persist secp256k1 keys here,
/// and `pay` / `sign --account` retrieve one for use.
///
/// Keys are raw bytes; address derivation is the caller's concern, so this layer stays crypto-free.
/// A real implementation guards key retrieval behind device authentication (see
/// ``makeAccountStore()`` / `KeychainAccountStore`). Listing names and reading the default pointer
/// are non-secret and do not prompt; only ``privateKey(name:)`` (retrieval) may.
public protocol AccountStore: Sendable {
    /// Stores `privateKey` under `name` with a non-secret `label` (the display address), replacing
    /// any existing entry.
    func store(_ privateKey: Data, name: String, label: String) throws
    /// The private key for `name`. May prompt for authentication; throws ``AccountStoreError`` if
    /// absent.
    func privateKey(name: String) throws -> Data
    /// All stored accounts as (name, label) - reads attributes only, so it does not prompt.
    func accounts() throws -> [Account]
    /// Removes the account `name` (a no-op if it is absent).
    func delete(name: String) throws
    /// The default account name, if one is set (does not prompt).
    func defaultName() throws -> String?
    /// Sets the default account name, or clears it with `nil`.
    func setDefaultName(_ name: String?) throws
}

/// A stored account's non-secret facts: its `name` and a display `label` (the address). The private
/// key is never part of this - it is read only via ``AccountStore/privateKey(name:)``.
public struct Account: Sendable, Hashable {
    public let name: String
    public let label: String
    public init(name: String, label: String) {
        self.name = name
        self.label = label
    }
}

/// A reason an ``AccountStore`` operation failed.
public enum AccountStoreError: Error, Sendable, Hashable {
    /// No account with this name is stored.
    case notFound(String)
    /// The underlying key store failed; the payload is a short diagnostic (never key material).
    case ioFailure(String)
}

/// The platform account store, or `nil` where no secure key store is available (for example Linux):
/// there, named accounts are unsupported and `MPP_PRIVATE_KEY` is the way to supply a key.
public func makeAccountStore() -> (any AccountStore)? {
    #if canImport(Security)
        return KeychainAccountStore()
    #else
        return nil
    #endif
}
