import Foundation
import MPPCore
import MPPEVM

/// A TIP-20 `transferWithMemo` decoded from a receipt event log: the settled-charge verifier reads
/// it to confirm a charge's `currency`, `from`/`to`, `amount`, and attribution `memo` actually
/// moved on-chain.
public struct TIP20Transfer: Sendable, Hashable {
    /// The token contract that emitted the event (the log's address).
    public let currency: EthereumAddress
    /// The payer the transfer moved funds from.
    public let from: EthereumAddress
    /// The payee the transfer moved funds to.
    public let recipient: EthereumAddress
    /// The amount transferred, as a canonical base-units ``Amount``.
    public let amount: Amount
    /// The 32-byte attribution memo carried by `transferWithMemo`.
    public let memo: Data

    /// Creates a decoded transfer (decoding is the usual path; this also lets a test build one).
    public init(
        currency: EthereumAddress,
        from: EthereumAddress,
        recipient: EthereumAddress,
        amount: Amount,
        memo: Data
    ) {
        self.currency = currency
        self.from = from
        self.recipient = recipient
        self.amount = amount
        self.memo = memo
    }
}

/// Decodes the TIP-20 `TransferWithMemo` event from a receipt log.
///
/// The event is `TransferWithMemo(address from indexed, address to indexed, uint256 amount,
/// bytes32 memo indexed)` (per the chain's TIP-20 ABI), so on the wire: `topics[0]` is the
/// signature hash, `topics[1]`/`topics[2]`/`topics[3]` are `from`/`to`/`memo` (each a 32-byte
/// word, addresses right-aligned in the low 20 bytes), and the non-indexed `amount` is the 32-byte
/// `data` word.
public enum TIP20TransferEvent {
    /// `keccak256("TransferWithMemo(address,address,uint256,bytes32)")` -- the event-signature
    /// topic that `topics[0]` must equal.
    public static let transferWithMemoTopic = Keccak256.hash(
        Data("TransferWithMemo(address,address,uint256,bytes32)".utf8)
    )

    /// Decodes `log` as a `TransferWithMemo`, or `nil` if it is a different event or malformed.
    public static func transferWithMemo(from log: EVMLog) -> TIP20Transfer? {
        guard log.topics.count == 4,
              let topic0 = Data(hexPrefixed: log.topics[0]), topic0 == transferWithMemoTopic,
              let currency = EthereumAddress(hex: log.address),
              let from = address(fromTopic: log.topics[1]),
              let recipient = address(fromTopic: log.topics[2]),
              let memo = Data(hexPrefixed: log.topics[3]), memo.count == 32,
              let dataWord = Data(hexPrefixed: log.data), dataWord.count == 32,
              let amount = try? Amount(EIP712.uint256Decimal(dataWord))
        else { return nil }
        return TIP20Transfer(
            currency: currency, from: from, recipient: recipient, amount: amount, memo: memo
        )
    }

    /// An address from a 32-byte indexed topic word: the address is right-aligned in the low 20
    /// bytes, and the high 12 bytes MUST be zero padding (EVM ABI). A non-zero high half is a
    /// malformed topic and is rejected, so a verifier never reads a corrupted word as a valid
    /// address.
    private static func address(fromTopic topic: String) -> EthereumAddress? {
        guard let word = Data(hexPrefixed: topic), word.count == 32,
              word.prefix(12).allSatisfy({ $0 == 0 })
        else { return nil }
        return EthereumAddress(bytes: Data(word.suffix(20)))
    }
}
