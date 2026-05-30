import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import MPPTempoServer
import Testing

// Shared fixtures for the MPPTempoServer test target (one home, not per-file copies).
// The key->signer helper lives in TempoProofVerifierTests (`signer(byte:)`, internal).
// `now` is the shared test clock from TempoProofVerifierTests (same target).

// MARK: - SessionMethod fixtures (shared by SessionMethodTests + close suite)

// Signer key=1 -> address 0x7E5F...Bdf, the channel's authorized signer.
let escrow = tempoTestAddress("0x5555555555555555555555555555555555555555")
let payee = tempoTestAddress("0x2222222222222222222222222222222222222222")
let token = tempoTestAddress("0x3333333333333333333333333333333333333333")
let channelID = Data(repeating: 0xAB, count: 32)
let chainID: UInt64 = 42431
let authorizedSigner = tempoTestAddress("0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")

func onChainChannel(
    deposit: UInt64 = 1000, settled: UInt64 = 0, finalized: Bool = false,
    closeRequestedAt: UInt64 = 0
) -> OnChainChannel {
    OnChainChannel(
        payer: payee, payee: payee, token: token, authorizedSigner: authorizedSigner,
        deposit: ChannelAmount(deposit), settled: ChannelAmount(settled),
        finalized: finalized, closeRequestedAt: closeRequestedAt
    )
}

/// Seeds the store with an open channel whose highest accepted voucher is `highest`.
func seedStore(highest: UInt64, spent: UInt64 = 0) async throws -> InMemoryChannelStore {
    let store = InMemoryChannelStore()
    // Store the real signature over the seeded highest voucher, so close paths
    // that settle the stored highest use a faithfully-signed voucher.
    let highestVoucher = try #require(
        Voucher(channelID: channelID, cumulativeAmount: String(highest))
    )
    let highestSignature = try highestVoucher.sign(
        escrowContract: escrow, chainId: chainID, with: signer(byte: 1)
    )
    _ = try await store.update(channelID) { _ in
        ChannelState(
            channelID: channelID, chainID: chainID, escrowContract: escrow,
            payer: payee, payee: payee, token: token, authorizedSigner: authorizedSigner,
            deposit: ChannelAmount(1000), highestVoucherAmount: ChannelAmount(highest),
            highestVoucherSignature: highestSignature,
            spent: ChannelAmount(spent)
        )
    }
    return store
}

func sessionChallenge(amount: String = "1") throws -> Challenge {
    let request = EncodedJSON(json: .object([
        "amount": .string(amount),
        "recipient": .string("0x2222222222222222222222222222222222222222"),
        "currency": .string("0x3333333333333333333333333333333333333333"),
        "methodDetails": .object([
            "chainId": .integer(Int64(chainID)),
            "escrowContract": .string("0x5555555555555555555555555555555555555555"),
        ]),
    ]))
    return try Challenge(
        id: "session-1", realm: "https://api.example.com",
        method: MethodName("tempo"), intent: .session, request: request
    )
}

func hex(_ data: Data) -> String {
    "0x" + data.map { String(format: "%02x", $0) }.joined()
}

/// A voucher-action credential signed by key=1 over `cumulative`.
func voucherCredential(
    cumulative: String, action: String = "voucher", amount: String = "1"
) throws -> Credential {
    let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: cumulative))
    let signature = try voucher.sign(
        escrowContract: escrow,
        chainId: chainID,
        with: signer(byte: 1)
    )
    return try Credential(
        challenge: sessionChallenge(amount: amount), source: nil,
        payload: [
            "action": .string(action),
            "channelId": .string(hex(channelID)),
            "cumulativeAmount": .string(cumulative),
            "signature": .string(hex(signature)),
        ]
    )
}

func sessionMethod(_ store: InMemoryChannelStore, _ provider: StubProvider) -> SessionMethod {
    SessionMethod(provider: provider, store: store, defaultChainID: chainID)
}

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
