import Foundation
import MPPClient
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import MPPTempoServer
import Testing
@testable import MPPTempoFFI

// The authoritative on-chain proof of the non-zero settled-charge rail (draft-tempo-charge-00):
// against live Moderato, fund a fresh payer, build a real tempo/charge credential with the client
// (TempoSettledChargeMethod over the FFI transfer builder) in BOTH submission modes, settle it with
// the server verifier (TempoSettledChargeVerifier over RPCChargeSettlement), and assert (1) the
// verifier mints a receipt referencing a real, mined, successful transaction, (2) the recipient's
// TIP-20 balance grew by exactly the charge amount, and (3) the settled hash is single-use.
//
//   - push / hash:        the CLIENT broadcasts (RPCTransferBroadcaster); the server reads the
//                         receipt for the named hash.
//   - pull / transaction: the CLIENT signs an expiring-nonce tx; the SERVER broadcasts it.
//
// This closes the loop the stub-based TempoSettledChargeVerifierTests cannot: it proves the FFI
// transfer encoding, the TransferWithMemo event decode, the memo binding, and both submission modes
// against the real chain. Gated behind MPP_MODERATO_E2E=1 (the same gate as the other live tests)
// AND requires the FFI; helpers come from ``ModeratoKit``. The CI `live-moderato` job runs it.
private let liveChargeEnabled = ProcessInfo.processInfo.environment["MPP_MODERATO_E2E"] == "1"

@Suite("Moderato settled-charge e2e")
struct ModeratoSettledChargeE2ETests {
    private static let amount: UInt64 = 1000
    private static let realm = "e2e-charge.example"

    @Test(
        "push/hash: the client broadcasts, the server settles from the receipt",
        .enabled(if: liveChargeEnabled)
    )
    func pushHashSettles() async throws {
        try await runCharge(modes: ["push"])
    }

    @Test(
        "pull/transaction: the client signs an expiring tx, the server broadcasts + settles",
        .enabled(if: liveChargeEnabled)
    )
    func pullTransactionSettles() async throws {
        try await runCharge(modes: ["pull"])
    }

    /// One full settled charge in the given mode: fund a fresh payer, build the credential
    /// (client), settle it (server), and assert the receipt, the recipient balance delta, and
    /// single-use.
    private func runCharge(modes: [String]) async throws {
        let rpc = try ModeratoKit.makeRPC()
        let token = try #require(EthereumAddress(hex: ModeratoKit.tokenHex))
        let payer = try await ModeratoKit.fundFreshAccount(rpc: rpc)
        let recipient = try #require(EthereumAddress(
            uncompressedPublicKey: Secp256k1Signer(privateKey: ModeratoKit.randomBytes()).publicKey
        ))
        let challenge = try chargeChallenge(recipient: recipient, currency: token, modes: modes)

        // Capture the recipient balance up front: in push mode the client broadcasts inside
        // buildCredential (so the transfer is already on-chain before verify), while in pull mode
        // the server broadcasts during verify -- reading before either path moves money is correct
        // for both.
        let before = try await ModeratoKit.balanceOf(token, recipient, rpc: rpc)

        // Client: build the credential over the live FFI transfer builder. Push injects a
        // broadcaster (the client submits); pull needs none (the server broadcasts).
        let fee = try await ModeratoKit.makeFee(rpc: rpc)
        let builder = FFITransferTxBuilder(fee: fee) { account in
            try await rpc.transactionCount(account)
        }
        let broadcaster = modes.contains("push") ? RPCTransferBroadcaster(rpc: rpc) : nil
        let client = try #require(TempoSettledChargeMethod(
            payerPrivateKey: payer.privateKey,
            transferBuilder: builder,
            broadcaster: broadcaster,
            defaultChainId: ModeratoKit.chainID
        ))
        #expect(client.supports(challenge))
        let credential = try await client.buildCredential(for: challenge)

        // Server: settle the credential on-chain (hash -> read the receipt; transaction ->
        // broadcast then read).
        let store = InMemoryReplayStore()
        let verifier = TempoSettledChargeVerifier(
            settlement: RPCChargeSettlement(rpc: rpc),
            replayStore: store,
            defaultChainId: ModeratoKit.chainID
        )
        let receipt = try await verifier.verify(credential, now: Date())

        // (1) the receipt references a real, mined, successful transaction.
        let onChain = try #require(await rpc.transactionReceipt(receipt.reference))
        #expect(onChain.succeeded)
        // (2) the recipient's balance grew by exactly the charge amount.
        let after = try await ModeratoKit.balanceOf(token, recipient, rpc: rpc)
        #expect(after == before + Self.amount)
        // (3) the settled hash is single-use: re-verifying the same credential is rejected (the
        // replay store has consumed the hash; in pull mode the re-broadcast also fails).
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.self) {
            _ = try await verifier.verify(credential, now: Date())
        }
    }

    /// A non-zero `tempo`/`charge` challenge for the live chain, advertising the given modes.
    private func chargeChallenge(
        recipient: EthereumAddress,
        currency: EthereumAddress,
        modes: [String]
    ) throws -> Challenge {
        let request = EncodedJSON(json: .object([
            "amount": .string(String(Self.amount)),
            "recipient": .string(recipient.bytes.hexPrefixed),
            "currency": .string(currency.bytes.hexPrefixed),
            "methodDetails": .object([
                "chainId": .integer(Int64(ModeratoKit.chainID)),
                "supportedModes": .array(modes.map(JSONValue.string)),
            ]),
        ]))
        return try Challenge(
            id: "settled-charge-e2e-\(modes.joined(separator: "-"))",
            realm: Self.realm,
            method: MethodName("tempo"),
            intent: IntentName("charge"),
            request: request
        )
    }
}
