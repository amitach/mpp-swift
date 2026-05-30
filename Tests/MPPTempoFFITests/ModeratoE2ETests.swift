import Foundation
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo
@testable import MPPTempoFFI

// The authoritative on-chain proof of the FFI write path: against the live Moderato
// testnet, fund a fresh account from the faucet, then build (via the Rust FFI), sign,
// broadcast, and confirm a real `open` and `close` of a payment channel. Gated behind
// MPP_MODERATO_E2E=1 (the same gate as the other live tests) AND requires MPP_TEMPO_FFI
// (this whole target only exists when the FFI is built); skipped otherwise, so default
// CI stays hermetic. The CI `live-moderato` job runs it.
//
// Self-contained: the Moderato faucet (`tempo_fundAddress`) funds a throwaway key with
// native gas + the TIP-20 tokens, so no secret or pre-funded account is needed. The
// funding / fee / broadcast helpers live in ``ModeratoKit`` (shared with the session
// conformance test).
private let liveEnabled = ProcessInfo.processInfo.environment["MPP_MODERATO_E2E"] == "1"

@Suite("Moderato FFI write-path e2e")
struct ModeratoE2ETests {
    @Test("fund -> open -> voucher -> close, confirmed on-chain", .enabled(if: liveEnabled))
    func openThenClose() async throws {
        let rpc = try ModeratoKit.makeRPC()
        let escrow = try #require(EthereumAddress(hex: ModeratoKit.escrowHex))
        let token = try #require(EthereumAddress(hex: ModeratoKit.tokenHex))

        // A fresh throwaway account, faucet-funded, so each run is independent (nonce
        // starts at 0, no pre-existing channels). authorizedSigner = payer = the sender.
        let signer = try await ModeratoKit.fundFreshAccount(rpc: rpc)
        let builder = try await ModeratoKit.makeBuilder(signingKey: signer.privateKey, rpc: rpc)
        let salt = ModeratoKit.randomBytes()

        // open: build (2-call approve + open) via the FFI, broadcast, confirm the deposit.
        let deposit: UInt64 = 1000
        let openParameters = TempoOpenParameters(
            escrow: escrow, token: token, payee: signer.address,
            deposit: String(deposit), salt: salt, authorizedSigner: signer.address
        )
        let open = try await builder.buildOpenTransaction(
            openParameters,
            chainID: ModeratoKit.chainID
        )
        try await ModeratoKit.broadcast(open, rpc: rpc)

        let parameters = try #require(Channel.Parameters(
            payer: signer.address, payee: signer.address, token: token, salt: salt,
            authorizedSigner: signer.address, escrowContract: escrow, chainId: ModeratoKit.chainID
        ))
        let channelID = Channel.id(parameters)
        let opened = try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
        #expect(opened.deposit == ChannelAmount(deposit))

        // close: settle a cumulative amount within the deposit, signed by the authorized
        // signer. The open tx is mined, so the builder reads nonce 1 for this tx.
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: "500"))
        let signature = try voucher.sign(
            escrowContract: escrow,
            chainId: ModeratoKit.chainID,
            with: signer.signer
        )
        let close = try await builder.buildCloseTransaction(
            voucher: voucher, signature: signature, escrow: escrow, chainID: ModeratoKit.chainID
        )
        try await ModeratoKit.broadcast(close, rpc: rpc)

        // `close` finalizes the channel on-chain (matches reference mppx, whose close test
        // asserts `finalized == true`; `settled` tracks withdrawals, a separate op).
        let closed = try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
        #expect(closed.finalized)
    }

    @Test(
        "the channel session drives open -> voucher -> topUp -> close on-chain",
        .enabled(if: liveEnabled)
    )
    func sessionLifecycle() async throws {
        let rpc = try ModeratoKit.makeRPC()
        let account = try await ModeratoKit.fundFreshAccount(rpc: rpc)
        let fee = try await ModeratoKit.makeFee(rpc: rpc)
        let session = try TempoChannelSession( // init is synchronous (no await)
            privateKey: account.privateKey,
            escrow: #require(EthereumAddress(hex: ModeratoKit.escrowHex)),
            token: #require(EthereumAddress(hex: ModeratoKit.tokenHex)),
            payee: account.address,
            salt: ModeratoKit.randomBytes(),
            fee: fee,
            chainID: ModeratoKit.chainID,
            rpc: rpc
        )
        let opened = try await session.open(deposit: "1000")
        #expect(opened.isOpen)
        #expect(opened.deposit == ChannelAmount(1000))

        let voucher = try await session.voucher(cumulativeAmount: "300")
        #expect(voucher.signature.count == 65)
        #expect(voucher.channelID == session.channelID)

        let toppedUp = try await session.topUp(additionalDeposit: "500")
        #expect(toppedUp.deposit == ChannelAmount(1500))

        let closed = try await session.close()
        #expect(closed.isFinalized)
    }
}
