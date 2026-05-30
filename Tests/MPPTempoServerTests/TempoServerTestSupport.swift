import Foundation
import MPPEVM
import MPPTempoServer

// Shared fixtures for the MPPTempoServer test target (one home, not per-file copies).
// The key->signer helper lives in TempoProofVerifierTests (`signer(byte:)`, internal).

/// Builds an ``EthereumAddress`` from a hex string, trapping on invalid input.
func tempoTestAddress(_ hex: String) -> EthereumAddress {
    guard let address = EthereumAddress(hex: hex) else {
        preconditionFailure("invalid test address \(hex)")
    }
    return address
}

/// A configurable stub `ChannelStateProvider`: returns a fixed on-chain snapshot and
/// records the settle / broadcast calls. Lives here so both SessionMethod suites share
/// one double.
final class StubProvider: ChannelStateProvider, @unchecked Sendable {
    var onChain: OnChainChannel
    private(set) var settleCalls = 0
    private(set) var openCalls = 0
    /// The cumulative amount of the voucher the last `settle` was called with.
    private(set) var settledCumulative: String?
    /// Runs during `settle` (the on-chain window), to probe concurrent access.
    var onSettle: (@Sendable () async -> Void)?
    init(_ onChain: OnChainChannel) {
        self.onChain = onChain
    }

    func channelState(
        channelID _: Data, escrow _: EthereumAddress, chainID _: UInt64
    ) async -> OnChainChannel {
        onChain
    }

    func broadcastOpen(
        serializedTransaction _: Data, channelID _: Data, escrow _: EthereumAddress,
        chainID _: UInt64
    ) async -> (state: OnChainChannel, txHash: String) {
        openCalls += 1
        return (onChain, "0xopen")
    }

    func broadcastTopUp(
        serializedTransaction _: Data, channelID _: Data, escrow _: EthereumAddress,
        chainID _: UInt64
    ) async -> (state: OnChainChannel, txHash: String) {
        (onChain, "0xtopup")
    }

    func settle(
        channelID _: Data, voucher: Voucher, signature _: Data, escrow _: EthereumAddress,
        chainID _: UInt64
    ) async -> String {
        settleCalls += 1
        settledCumulative = voucher.cumulativeAmount
        await onSettle?()
        return "0xsettle"
    }
}

/// A minimal mutable flag for capturing a result from a `@Sendable` closure in a test.
/// The session flow awaits the closure sequentially, so no real locking is needed;
/// `@unchecked Sendable` only satisfies the closure's capture requirement.
final class Flag: @unchecked Sendable {
    private var value: Bool
    init(_ value: Bool) {
        self.value = value
    }

    func set(_ newValue: Bool) {
        value = newValue
    }

    func get() -> Bool {
        value
    }
}
