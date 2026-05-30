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
// native gas + the TIP-20 tokens, so no secret or pre-funded account is needed.
private let liveEnabled = ProcessInfo.processInfo.environment["MPP_MODERATO_E2E"] == "1"

@Suite("Moderato FFI write-path e2e")
struct ModeratoE2ETests {
    private let chainID = TempoChain.moderatoTestnet // 42431
    private let escrowHex = "0xe1c4d3dce17bc111181ddf716f75bae49e61a336"
    private let tokenHex = "0x20c0000000000000000000000000000000000000"

    @Test("fund -> open -> voucher -> close, confirmed on-chain", .enabled(if: liveEnabled))
    func openThenClose() async throws {
        let rpc = try EVMRPC(
            transport: URLSessionTransport(),
            url: #require(URL(string: "https://rpc.moderato.tempo.xyz"))
        )
        let escrow = try #require(EthereumAddress(hex: escrowHex))
        let token = try #require(EthereumAddress(hex: tokenHex))

        // A fresh throwaway account, faucet-funded, so each run is independent (nonce
        // starts at 0, no pre-existing channels). authorizedSigner = payer = the sender.
        let signer = try await fundFreshAccount(rpc: rpc)
        let builder = try await makeBuilder(signingKey: signer.privateKey, rpc: rpc)
        let salt = randomBytes()

        // open: build (2-call approve + open) via the FFI, broadcast, confirm the deposit.
        let deposit: UInt64 = 1000
        let openParameters = TempoOpenParameters(
            escrow: escrow, token: token, payee: signer.address,
            deposit: String(deposit), salt: salt, authorizedSigner: signer.address
        )
        let open = try await builder.buildOpenTransaction(openParameters, chainID: chainID)
        try await broadcast(open, rpc: rpc)

        let parameters = try #require(Channel.Parameters(
            payer: signer.address, payee: signer.address, token: token, salt: salt,
            authorizedSigner: signer.address, escrowContract: escrow, chainId: chainID
        ))
        let channelID = Channel.id(parameters)
        let opened = try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
        #expect(opened.deposit == ChannelAmount(deposit))

        // close: settle a cumulative amount within the deposit, signed by the authorized
        // signer. The open tx is mined, so the builder reads nonce 1 for this tx.
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: "500"))
        let signature = try voucher.sign(
            escrowContract: escrow,
            chainId: chainID,
            with: signer.signer
        )
        let close = try await builder.buildCloseTransaction(
            voucher: voucher, signature: signature, escrow: escrow, chainID: chainID
        )
        try await broadcast(close, rpc: rpc)

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
        let rpc = try EVMRPC(
            transport: URLSessionTransport(),
            url: #require(URL(string: "https://rpc.moderato.tempo.xyz"))
        )
        let account = try await fundFreshAccount(rpc: rpc)
        let fee = try await makeFee(rpc: rpc)
        let session = try TempoChannelSession( // init is synchronous (no await)
            privateKey: account.privateKey,
            escrow: #require(EthereumAddress(hex: escrowHex)),
            token: #require(EthereumAddress(hex: tokenHex)),
            payee: account.address,
            salt: randomBytes(),
            fee: fee,
            chainID: chainID,
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

    // MARK: - Phases

    private struct Account {
        let privateKey: Data
        let signer: Secp256k1Signer
        let address: EthereumAddress
    }

    /// Generates a throwaway key, funds its address via the faucet, and waits for the
    /// funding transactions to mine.
    private func fundFreshAccount(rpc: EVMRPC) async throws -> Account {
        let privateKey = randomBytes()
        let signer = try Secp256k1Signer(privateKey: privateKey)
        let address = try #require(EthereumAddress(uncompressedPublicKey: signer.publicKey))
        let funded = try await rpc.request(
            "tempo_fundAddress", params: .array([.string(address.bytes.hexPrefixed)])
        )
        let fundingHashes = try hashes(funded)
        #expect(!fundingHashes.isEmpty)
        for hash in fundingHashes {
            try await waitForSuccess(hash, rpc: rpc)
        }
        return Account(privateKey: privateKey, signer: signer, address: address)
    }

    /// Fee params that pay native gas (the faucet grant is abundant), a generous gas
    /// limit, priority 0 (Moderato reports eth_maxPriorityFeePerGas 0).
    private func makeFee(rpc: EVMRPC) async throws -> TempoFeeParameters {
        let gasPrice = try await rpc.gasPrice()
        return TempoFeeParameters(
            maxFeePerGas: String(gasPrice * 2),
            maxPriorityFeePerGas: "0",
            gasLimit: 2_000_000,
            feeToken: nil
        )
    }

    /// A builder over the live chain (nonce read per call).
    private func makeBuilder(signingKey: Data, rpc: EVMRPC) async throws -> FFITempoTxBuilder {
        try await FFITempoTxBuilder(
            signingKey: signingKey,
            fee: makeFee(rpc: rpc),
            nonceProvider: { address in try await rpc.transactionCount(address) }
        )
    }

    /// Broadcasts a raw transaction with the submit-and-wait sync send and asserts success.
    private func broadcast(_ raw: Data, rpc: EVMRPC) async throws {
        let receipt = try await rpc.sendRawTransactionSync(raw)
        guard receipt.succeeded
        else { throw E2EError.unexpected("tx \(receipt.transactionHash) reverted") }
    }

    // MARK: - Helpers

    private func randomBytes() -> Data {
        Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
    }

    private func hashes(_ value: JSONValue) throws -> [String] {
        guard case let .array(items) = value else {
            throw E2EError.unexpected("expected a JSON array of tx hashes")
        }
        return try items.map { item in
            guard case let .string(hash) = item else {
                throw E2EError.unexpected("tx hash is not a string")
            }
            return hash
        }
    }

    /// Polls `eth_getTransactionReceipt` until the transaction is mined, then asserts it
    /// succeeded. Fails the test if it does not mine within the budget.
    private func waitForSuccess(_ hash: String, rpc: EVMRPC) async throws {
        for _ in 0 ..< 60 {
            if let receipt = try await rpc.transactionReceipt(hash) {
                // Throw (not a soft #expect) so a revert hard-stops the flow rather than
                // cascading into reads of a channel that never opened/closed.
                guard receipt.succeeded else { throw E2EError.unexpected("tx \(hash) reverted") }
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw E2EError.unexpected("tx \(hash) not mined within 60s")
    }
}

private enum E2EError: Error { case unexpected(String) }
