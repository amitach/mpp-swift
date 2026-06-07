import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo
@testable import MPPTempoFFI

// Shared live-Moderato test helpers: faucet funding, fee/builder construction, and
// submit-and-wait broadcast. Used by the FFI write-path e2e (ModeratoE2ETests) and the
// cross-SDK session conformance test, so the funding/broadcast logic lives in ONE place.
// Live-gated callers only (the helpers contact the real testnet); namespaced under
// `ModeratoKit` to avoid colliding with any other test's helpers.
enum ModeratoKit {
    /// Moderato testnet chain id.
    static let chainID = TempoChain.moderatoTestnet // 42431
    /// The deployed stream-channel escrow on Moderato.
    static let escrowHex = "0xe1c4d3dce17bc111181ddf716f75bae49e61a336"
    /// A Moderato TIP-20 token the faucet grants and channels denominate in.
    static let tokenHex = "0x20c0000000000000000000000000000000000000"
    /// The Moderato JSON-RPC endpoint.
    static let rpcURLString = "https://rpc.moderato.tempo.xyz"

    /// A live-chain RPC client over `URLSessionTransport`, wrapped to retry the public Moderato
    /// RPC's transient throttling (see ``RetryingTransport``).
    static func makeRPC() throws -> EVMRPC {
        let transport = RetryingTransport(base: URLSessionTransport())
        return try EVMRPC(transport: transport, url: #require(URL(string: rpcURLString)))
    }

    /// A funded throwaway account: a fresh key, its faucet grant mined.
    struct Account {
        let privateKey: Data
        let signer: Secp256k1Signer
        let address: EthereumAddress
    }

    /// Generates a throwaway key, funds its address via the faucet (`tempo_fundAddress`,
    /// native gas + the TIP-20 tokens), and waits for the funding transactions to mine.
    static func fundFreshAccount(rpc: EVMRPC) async throws -> Account {
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
    static func makeFee(rpc: EVMRPC) async throws -> TempoFeeParameters {
        let gasPrice = try await rpc.gasPrice()
        return TempoFeeParameters(
            maxFeePerGas: String(gasPrice * 2),
            maxPriorityFeePerGas: "0",
            gasLimit: 2_000_000,
            feeToken: nil
        )
    }

    /// A builder over the live chain (nonce read per call).
    static func makeBuilder(signingKey: Data, rpc: EVMRPC) async throws -> FFITempoTxBuilder {
        try await FFITempoTxBuilder(
            signingKey: signingKey,
            fee: makeFee(rpc: rpc),
            nonceProvider: { address in try await rpc.transactionCount(address) }
        )
    }

    /// Broadcasts a raw transaction with the submit-and-wait sync send and asserts success.
    static func broadcast(_ raw: Data, rpc: EVMRPC) async throws {
        let receipt = try await rpc.sendRawTransactionSync(raw)
        guard receipt.succeeded else {
            throw ModeratoError.unexpected("tx \(receipt.transactionHash) reverted")
        }
    }

    /// 32 random bytes (a throwaway private key or salt).
    static func randomBytes() -> Data {
        Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
    }

    /// Parses a JSON array of `0x`-prefixed transaction hashes.
    static func hashes(_ value: JSONValue) throws -> [String] {
        guard case let .array(items) = value else {
            throw ModeratoError.unexpected("expected a JSON array of tx hashes")
        }
        return try items.map { item in
            guard case let .string(hash) = item else {
                throw ModeratoError.unexpected("tx hash is not a string")
            }
            return hash
        }
    }

    /// Polls `eth_getTransactionReceipt` until the transaction is mined, then asserts it
    /// succeeded. Throws (not a soft `#expect`) so a revert hard-stops the flow rather than
    /// cascading into reads of state that never changed. Fails if not mined within 60s.
    static func waitForSuccess(_ hash: String, rpc: EVMRPC) async throws {
        for _ in 0 ..< 60 {
            if let receipt = try await rpc.transactionReceipt(hash) {
                guard receipt.succeeded else {
                    throw ModeratoError.unexpected("tx \(hash) reverted")
                }
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ModeratoError.unexpected("tx \(hash) not mined within 60s")
    }

    /// TIP-20 `balanceOf(owner)` via `eth_call`; the live e2e amounts are small, so the low 8 bytes
    /// of the uint256 result suffice. Shared by the settled-charge and subscription e2es.
    static func balanceOf(
        _ token: EthereumAddress, _ owner: EthereumAddress, rpc: EVMRPC
    ) async throws -> UInt64 {
        let selector = Data([0x70, 0xA0, 0x82, 0x31]) // balanceOf(address)
        let data = selector + Data(repeating: 0, count: 12) + owner.bytes
        let result = try await rpc.call(to: token, data: data)
        return result.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

/// A failure in a live-Moderato test helper.
enum ModeratoError: Error { case unexpected(String) }

/// An ``MPPHTTPTransport`` that retries the public Moderato RPC on transient failures the shared
/// testnet exhibits under load: throttling / availability *responses* (HTTP 429 Too Many Requests,
/// 502, 503 -- which ``EVMRPC`` turns into ``EVMRPC/EVMRPCError/httpStatus(_:)``), and transport
/// *throws* (connection reset, TLS, timeout). Without this the live e2es flake on infrastructure
/// rather than logic. Both are "try again" conditions, so retrying with bounded exponential backoff
/// (capped ~4s, ~16s total) is the correct client behavior and weakens no on-chain assertion.
/// Test-only.
struct RetryingTransport: MPPHTTPTransport {
    let base: any MPPHTTPTransport
    let maxAttempts: Int

    /// - Parameter maxAttempts: total tries including the first (8 -> up to 7 backoff waits).
    init(base: any MPPHTTPTransport, maxAttempts: Int = 8) {
        self.base = base
        self.maxAttempts = maxAttempts
    }

    private static let retryableStatuses: Set<Int> = [429, 502, 503]

    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        var attempt = 0
        while true {
            attempt += 1
            let isFinalAttempt = attempt >= maxAttempts
            do {
                let (response, data) = try await base.send(request, body: body)
                if isFinalAttempt || !Self.retryableStatuses.contains(response.status.code) {
                    return (response, data)
                }
                // A retryable status with attempts left: fall through to back off and retry.
            } catch {
                // A transport-level failure (connection reset, TLS, timeout) under load: retry it
                // too, unless this was the last attempt.
                if isFinalAttempt { throw error }
            }
            // Exponential backoff capped at 4s, plus jitter to desynchronize concurrent retries.
            let backoffMs = min(UInt64(250) << UInt64(attempt - 1), 4000)
            try await Task.sleep(for: .milliseconds(backoffMs + UInt64.random(in: 0 ... 250)))
        }
    }
}
