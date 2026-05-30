import Foundation
import MPPEVM
import MPPTempo

/// The server's per-channel session accounting: a channel's identity, its on-chain
/// balance snapshot, the highest voucher accepted so far, and the current session's
/// spend counters.
///
/// Vouchers are cumulative and monotonic (``Voucher``): each authorizes a running
/// total, and the server records the highest it has accepted. `spent` / `units`
/// count what the session has drawn against that authorized total; the available
/// balance is `highestVoucherAmount - spent`. The on-chain fields
/// (``deposit``, ``settledOnChain``, ``authorizedSigner``, ...) are a snapshot the
/// server populates from the escrow when the channel opens; this off-chain record
/// does not read them itself.
public struct ChannelState: Sendable, Hashable {
    /// The 32-byte channel id (``Channel/id(_:)``).
    public var channelID: Data
    public var chainID: UInt64
    public var escrowContract: EthereumAddress
    public var payer: EthereumAddress
    public var payee: EthereumAddress
    public var token: EthereumAddress
    /// The address authorized to sign vouchers for the payer.
    public var authorizedSigner: EthereumAddress
    /// On-chain deposit backing the channel.
    public var deposit: ChannelAmount
    /// Amount already settled on-chain.
    public var settledOnChain: ChannelAmount
    /// The highest cumulative voucher amount accepted so far.
    public var highestVoucherAmount: ChannelAmount
    /// The 65-byte signature of the highest accepted voucher, if any.
    public var highestVoucherSignature: Data?
    /// Amount drawn from the channel this session.
    public var spent: ChannelAmount
    /// Number of charges this session.
    public var units: UInt64
    /// The channel has been finalized (closed on-chain); no further spend.
    public var finalized: Bool
    /// A close has been requested; no further spend.
    public var closing: Bool

    public init(
        channelID: Data,
        chainID: UInt64,
        escrowContract: EthereumAddress,
        payer: EthereumAddress,
        payee: EthereumAddress,
        token: EthereumAddress,
        authorizedSigner: EthereumAddress,
        deposit: ChannelAmount,
        settledOnChain: ChannelAmount = .zero,
        highestVoucherAmount: ChannelAmount = .zero,
        highestVoucherSignature: Data? = nil,
        spent: ChannelAmount = .zero,
        units: UInt64 = 0,
        finalized: Bool = false,
        closing: Bool = false
    ) {
        self.channelID = channelID
        self.chainID = chainID
        self.escrowContract = escrowContract
        self.payer = payer
        self.payee = payee
        self.token = token
        self.authorizedSigner = authorizedSigner
        self.deposit = deposit
        self.settledOnChain = settledOnChain
        self.highestVoucherAmount = highestVoucherAmount
        self.highestVoucherSignature = highestVoucherSignature
        self.spent = spent
        self.units = units
        self.finalized = finalized
        self.closing = closing
    }

    /// The amount still drawable this session: `highestVoucherAmount - spent`
    /// (clamped at zero, which only arises from an inconsistent record).
    public var available: ChannelAmount {
        highestVoucherAmount.subtracting(spent) ?? .zero
    }

    /// Returns a copy with `amount` drawn against the available balance (`spent`
    /// advanced, `units` incremented), or `nil` if the balance is insufficient.
    func recordingSpend(of amount: ChannelAmount) -> ChannelState? {
        guard available >= amount, let newSpent = spent.adding(amount) else { return nil }
        var copy = self
        copy.spent = newSpent
        copy.units += 1
        return copy
    }
}

/// Persistence for ``ChannelState`` with atomic read-modify-write, so concurrent
/// charges on one channel cannot race its spend counters.
///
/// This is the off-chain accounting seam: an in-memory implementation suits a
/// single process; a deployment that shares state across instances backs it with a
/// store offering atomic updates (the same plug-in pattern as ``ReplayStore``).
public protocol ChannelStore: Sendable {
    /// The current state for `channelID`, or `nil` if unknown.
    func channel(_ channelID: Data) async -> ChannelState?

    /// Atomically reads the state for `channelID`, applies `transform`, and stores
    /// the result (or removes it when `transform` returns `nil`). `transform` runs
    /// under the store's serialization, so its read-modify-write is atomic. It may
    /// throw to abort the update without writing.
    @discardableResult
    func update(
        _ channelID: Data,
        _ transform: @Sendable (ChannelState?) throws -> ChannelState?
    ) async throws -> ChannelState?
}

/// An in-memory ``ChannelStore`` backed by an actor, suitable for a single process
/// and for tests. The actor serializes ``update(_:_:)``, giving the atomic
/// read-modify-write guarantee.
public actor InMemoryChannelStore: ChannelStore {
    private var channels: [Data: ChannelState] = [:]

    public init() {}

    public func channel(_ channelID: Data) -> ChannelState? {
        channels[channelID]
    }

    @discardableResult
    public func update(
        _ channelID: Data,
        _ transform: @Sendable (ChannelState?) throws -> ChannelState?
    ) throws -> ChannelState? {
        let next = try transform(channels[channelID])
        channels[channelID] = next
        return next
    }
}

/// A reason a channel operation failed.
public enum ChannelError: Error, Sendable, Hashable {
    /// No channel is recorded for the id.
    case notFound
    /// The channel is finalized or closing; no further spend is allowed.
    case closed(reason: String)
    /// The requested amount exceeds the available balance.
    case insufficientBalance(requested: ChannelAmount, available: ChannelAmount)
}

/// Atomically draws `amount` from a channel's available balance, advancing its
/// spend counters.
///
/// - Throws: ``ChannelError/notFound`` if the channel is unknown,
///   ``ChannelError/closed(reason:)`` if it is finalized or closing, or
///   ``ChannelError/insufficientBalance(requested:available:)`` if the draw exceeds
///   the available balance. On any throw the channel is left unchanged.
@discardableResult
public func deductFromChannel(
    _ store: any ChannelStore,
    channelID: Data,
    amount: ChannelAmount
) async throws -> ChannelState {
    let updated = try await store.update(channelID) { current in
        guard let state = current else { throw ChannelError.notFound }
        guard !state.finalized else { throw ChannelError.closed(reason: "finalized") }
        guard !state.closing else { throw ChannelError.closed(reason: "closing") }
        guard let next = state.recordingSpend(of: amount) else {
            throw ChannelError.insufficientBalance(requested: amount, available: state.available)
        }
        return next
    }
    // update returns nil only if the transform returned nil, which it never does on
    // the success path (it either returns a state or throws).
    guard let updated else { throw ChannelError.notFound }
    return updated
}
