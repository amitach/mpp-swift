import Foundation
import MPPEVM
import MPPTempo

/// A signed session voucher: the channel id, the cumulative authorized amount, and the
/// 65-byte secp256k1 signature (`r ‖ s ‖ v`) the escrow recovers to the authorized
/// signer. This is the credential a payer hands a payee for an off-chain payment, and
/// the input the channel `close` settles.
public struct SignedVoucher: Sendable, Hashable {
    /// The 32-byte channel id.
    public let channelID: Data
    /// The cumulative authorized amount, as a base-10 `uint128` string.
    public let cumulativeAmount: String
    /// The 65-byte `r ‖ s ‖ v` voucher signature.
    public let signature: Data
}

/// A snapshot of a channel session's state.
public struct ChannelSessionState: Sendable, Hashable {
    /// The 32-byte channel id (deterministic from the channel parameters).
    public let channelID: Data
    /// The on-chain deposit last read from the escrow.
    public let deposit: ChannelAmount
    /// The cumulative amount of the latest issued voucher (0 if none issued).
    public let cumulativeAmount: ChannelAmount
    /// Whether `open` has confirmed on-chain.
    public let isOpen: Bool
    /// Whether `close` has finalized the channel on-chain.
    public let isFinalized: Bool
}

/// A reason a channel session operation failed.
public enum TempoChannelSessionError: Error, Sendable, Equatable {
    /// The signing key was not a valid secp256k1 private key.
    case invalidSigningKey
    /// The operation requires an open channel, but it is not open.
    case notOpen
    /// `open` was called on an already-open channel.
    case alreadyOpen
    /// The channel is finalized; no further operations are allowed.
    case alreadyFinalized
    /// A voucher's cumulative amount did not strictly increase.
    case nonMonotonicVoucher
    /// A voucher's cumulative amount exceeded the on-chain deposit.
    case voucherExceedsDeposit
    /// An amount was not a base-10 integer in range (names the field).
    case invalidAmount(String)
    /// A broadcast transaction reverted on-chain.
    case transactionReverted(String)
    /// A transaction was submitted (the carried hash) but did not mine within the polling
    /// budget. The on-chain outcome is UNKNOWN: do not blindly retry (it may yet land);
    /// read the channel state to reconcile.
    case receiptTimeout(String)
    /// Signing a voucher failed.
    case signingFailed
    /// Another lifecycle operation (open/topUp/close) is already in flight. The session is
    /// driven sequentially; await one operation before starting the next.
    case operationInProgress
    /// A prior operation's transaction was submitted but its receipt never confirmed
    /// (a ``receiptTimeout``), so the on-chain outcome is unknown and the session cannot
    /// safely continue (a further write could collide on the nonce or duplicate the
    /// effect). Reconcile the channel's on-chain state, then start a fresh session.
    case sessionUnusable
}

/// Drives the on-chain lifecycle of a single Tempo payment channel for one account:
/// `open`, `topUp`, `voucher` (off-chain), and `close`. It builds the `0x76`
/// transactions via the Rust FFI (``FFITempoTxBuilder``), broadcasts and confirms them
/// over ``EVMRPC``, reads channel state from the escrow (``TempoEscrow``), and signs
/// vouchers with the account key.
///
/// It is an `actor`, so synchronous access to its state is race-free. But actor
/// reentrancy means another method can run at an `await` suspension point, which would
/// break nonce sequencing if two writes interleaved (both reading the same nonce). So the
/// session is **driven sequentially**: an explicit in-flight guard rejects a concurrent
/// `open`/`topUp`/`close` with ``TempoChannelSessionError/operationInProgress``. Driven
/// that way (await one op before the next), the writes are nonce-sequenced correctly (a
/// fresh account's `open` is nonce 0, the next write nonce 1, and so on).
///
/// This is the self-managing-wallet (direct on-chain) path: it builds, broadcasts, and
/// confirms its own transactions. The 402-server path (emitting the session payloads a
/// server relays/settles) builds on these same primitives in a later workstream.
public actor TempoChannelSession {
    private let escrow: EthereumAddress
    private let token: EthereumAddress
    private let payee: EthereumAddress
    private let authorizedSigner: EthereumAddress
    private let salt: Data
    private let chainID: UInt64
    private let signer: Secp256k1Signer
    private let builder: FFITempoTxBuilder
    private let rpc: EVMRPC
    private let pollInterval: Duration
    private let maxPollAttempts: Int

    /// The 32-byte channel id, derived deterministically from the channel parameters at
    /// init (the same id the escrow computes from `open`). Readable without `await`.
    public nonisolated let channelID: Data

    private var deposit: ChannelAmount = .zero
    private var cumulative: ChannelAmount = .zero
    private var lastVoucher: SignedVoucher?
    private var opened = false
    private var finalized = false
    // True while an async lifecycle op holds the session. Set/checked synchronously (no
    // await between check and set), so it serializes ops despite actor reentrancy.
    private var inFlight = false
    // Set when a submitted transaction's receipt never confirmed: the on-chain outcome is
    // unknown, so no further operation may run (it could collide on the nonce or duplicate).
    private var poisoned = false

    /// Creates a session for the channel funded and signed by `privateKey` (the payer,
    /// which is also the voucher-authorized signer). `payee` is the channel recipient,
    /// `salt` (32 bytes) distinguishes channels that share every other parameter, and
    /// `fee` is the gas/fee parameters the transactions carry.
    public init(
        privateKey: Data,
        escrow: EthereumAddress,
        token: EthereumAddress,
        payee: EthereumAddress,
        salt: Data,
        fee: TempoFeeParameters,
        chainID: UInt64,
        rpc: EVMRPC,
        pollInterval: Duration = .seconds(1),
        maxPollAttempts: Int = 60
    ) throws(TempoChannelSessionError) {
        let signer: Secp256k1Signer
        do {
            signer = try Secp256k1Signer(privateKey: privateKey)
        } catch {
            throw .invalidSigningKey
        }
        guard let sender = EthereumAddress(uncompressedPublicKey: signer.publicKey) else {
            throw .invalidSigningKey
        }
        guard let parameters = Channel.Parameters(
            payer: sender, payee: payee, token: token, salt: salt,
            authorizedSigner: sender, escrowContract: escrow, chainId: chainID
        ) else {
            throw .invalidAmount("salt: must be 32 bytes")
        }
        self.escrow = escrow
        self.token = token
        self.payee = payee
        authorizedSigner = sender
        self.salt = salt
        self.chainID = chainID
        self.signer = signer
        self.rpc = rpc
        self.pollInterval = pollInterval
        self.maxPollAttempts = maxPollAttempts
        channelID = Channel.id(parameters)
        builder = FFITempoTxBuilder(
            signingKey: privateKey,
            fee: fee,
            nonceProvider: { address in try await rpc.transactionCount(address) }
        )
    }

    /// The current state snapshot.
    public func state() -> ChannelSessionState {
        ChannelSessionState(
            channelID: channelID, deposit: deposit, cumulativeAmount: cumulative,
            isOpen: opened, isFinalized: finalized
        )
    }

    /// Opens the channel with `deposit` (a base-10 `uint128` string): builds + broadcasts
    /// the `open` transaction, then reads back the on-chain deposit. Returns the new state.
    public func open(deposit: String) async throws -> ChannelSessionState {
        try beginOperation()
        defer { inFlight = false }
        guard !opened else { throw TempoChannelSessionError.alreadyOpen }
        guard ChannelAmount(decimal: deposit) != nil else {
            throw TempoChannelSessionError.invalidAmount("deposit")
        }
        let parameters = TempoOpenParameters(
            escrow: escrow, token: token, payee: payee,
            deposit: deposit, salt: salt, authorizedSigner: authorizedSigner
        )
        let transaction = try await builder.buildOpenTransaction(parameters, chainID: chainID)
        try await broadcast(transaction)
        // The open tx confirmed, so the channel IS open: record that BEFORE the deposit
        // read-back, so a read failure here cannot leave the session thinking it is unopened
        // (which would let a retry double-open the same channel).
        opened = true
        self.deposit = try await readChannel().deposit // `self.` so it is not the parameter
        return state()
    }

    /// Tops the channel up by `additionalDeposit` (a base-10 string): builds + broadcasts
    /// the `topUp` transaction, then re-reads the on-chain deposit.
    public func topUp(additionalDeposit: String) async throws -> ChannelSessionState {
        try beginOperation()
        defer { inFlight = false }
        try requireOpen()
        guard ChannelAmount(decimal: additionalDeposit) != nil else {
            throw TempoChannelSessionError.invalidAmount("additionalDeposit")
        }
        let transaction = try await builder.buildTopUpTransaction(
            escrow: escrow, token: token, channelID: channelID,
            additionalDeposit: additionalDeposit, chainID: chainID
        )
        try await broadcast(transaction)
        deposit = try await readChannel().deposit
        return state()
    }

    /// Signs a voucher for `cumulativeAmount` (a base-10 `uint128` string) and records it
    /// as the latest. Off-chain: no transaction. The amount must strictly increase over
    /// the previous voucher and not exceed the on-chain deposit. Returns the credential.
    public func voucher(cumulativeAmount: String) throws -> SignedVoucher {
        // Synchronous (no await), so it runs atomically on the actor and cannot itself
        // interleave; but reject it while an async write is mid-flight, so a voucher is
        // never issued against state a topUp/open/close is concurrently changing.
        guard !poisoned else { throw TempoChannelSessionError.sessionUnusable }
        guard !inFlight else { throw TempoChannelSessionError.operationInProgress }
        try requireOpen()
        guard let amount = ChannelAmount(decimal: cumulativeAmount) else {
            throw TempoChannelSessionError.invalidAmount("cumulativeAmount")
        }
        guard amount > cumulative else { throw TempoChannelSessionError.nonMonotonicVoucher }
        guard amount <= deposit else { throw TempoChannelSessionError.voucherExceedsDeposit }
        let signed = try sign(cumulativeAmount: cumulativeAmount)
        cumulative = amount
        lastVoucher = signed
        return signed
    }

    /// Closes (settles + finalizes) the channel on-chain using the latest issued voucher
    /// (or a zero-amount voucher if none was issued): builds + broadcasts the `close`
    /// transaction and confirms the channel is finalized.
    public func close() async throws -> ChannelSessionState {
        try beginOperation()
        defer { inFlight = false }
        try requireOpen()
        let voucher = try lastVoucher ?? sign(cumulativeAmount: "0")
        guard let parsed = Voucher(
            channelID: channelID,
            cumulativeAmount: voucher.cumulativeAmount
        ) else {
            throw TempoChannelSessionError.invalidAmount("cumulativeAmount")
        }
        let transaction = try await builder.buildCloseTransaction(
            voucher: parsed, signature: voucher.signature, escrow: escrow, chainID: chainID
        )
        try await broadcast(transaction)
        // A confirmed close finalizes the channel on-chain (the escrow's close finalizes;
        // see ModeratoE2ETests). Record it from the confirmed tx, not a separate read-back,
        // so a read failure cannot leave the session thinking the channel is still open.
        finalized = true
        return state()
    }

    // MARK: - Internals

    /// The shared prelude for the async lifecycle ops: rejects a poisoned session and a
    /// concurrent op, then takes the in-flight lock. The check-then-set is synchronous (no
    /// await between), so it is atomic on the actor despite reentrancy. The caller pairs it
    /// with `defer { inFlight = false }`.
    private func beginOperation() throws(TempoChannelSessionError) {
        guard !poisoned else { throw .sessionUnusable }
        guard !inFlight else { throw .operationInProgress }
        inFlight = true
    }

    private func requireOpen() throws(TempoChannelSessionError) {
        guard !finalized else { throw .alreadyFinalized }
        guard opened else { throw .notOpen }
    }

    private func sign(cumulativeAmount: String) throws(TempoChannelSessionError) -> SignedVoucher {
        guard let voucher = Voucher(channelID: channelID, cumulativeAmount: cumulativeAmount) else {
            throw .invalidAmount("cumulativeAmount")
        }
        let signature: Data
        do {
            signature = try voucher.sign(escrowContract: escrow, chainId: chainID, with: signer)
        } catch {
            throw .signingFailed
        }
        return SignedVoucher(
            channelID: channelID, cumulativeAmount: cumulativeAmount, signature: signature
        )
    }

    private func readChannel() async throws -> OnChainChannel {
        try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
    }

    /// Broadcasts a raw transaction and polls for its receipt. The three failure outcomes
    /// are distinguishable so the caller knows whether the transaction reached the chain:
    /// a thrown `EVMRPCError` (from `sendRawTransaction`) means it was NOT submitted (safe
    /// to retry); `transactionReverted` means it was submitted and failed; `receiptTimeout`
    /// means it WAS submitted but is unconfirmed (outcome unknown, do not blindly retry).
    private func broadcast(_ raw: Data) async throws {
        let hash = try await rpc.sendRawTransaction(raw)
        for _ in 0 ..< maxPollAttempts {
            if let receipt = try await rpc.transactionReceipt(hash) {
                guard receipt.succeeded else {
                    throw TempoChannelSessionError.transactionReverted(hash)
                }
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        // Submitted but unconfirmed: the on-chain outcome (and whether the nonce was
        // consumed) is unknown, so poison the session. The in-flight lock is still released
        // by the caller's defer, but `poisoned` blocks any further operation.
        poisoned = true
        throw TempoChannelSessionError.receiptTimeout(hash)
    }
}
