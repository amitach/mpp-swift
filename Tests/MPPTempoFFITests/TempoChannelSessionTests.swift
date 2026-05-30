import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo
@testable import MPPTempoFFI

// Hermetic coverage of the channel-session state machine + validation, driven by a
// method-aware stub transport (no network). The full happy path against the real chain
// is in ModeratoE2ETests (gated). Here we exercise the guards and the off-chain voucher
// logic the live happy path does not: lifecycle ordering, monotonic + over-deposit
// voucher rejection, and that state transitions track the (stubbed) on-chain reads.

@Suite("TempoChannelSession")
struct TempoChannelSessionTests {
    private let chainID: UInt64 = 42431
    private let privateKey = Data(repeating: 0x11, count: 32)
    private let salt = Data(repeating: 0xAB, count: 32)
    private let fee = TempoFeeParameters(
        maxFeePerGas: "1000000000", maxPriorityFeePerGas: "0", gasLimit: 2_000_000
    )

    private func address(_ byte: UInt8) throws -> EthereumAddress {
        try #require(EthereumAddress(bytes: Data(repeating: byte, count: 20)))
    }

    /// A session backed by a stub that reports the given on-chain `deposit` and
    /// `finalized` for every `getChannel`, and succeeds every send/receipt.
    private func makeSession(deposit: UInt64, finalized: Bool) throws -> TempoChannelSession {
        let stub = StubRPC(channelDeposit: deposit, channelFinalized: finalized)
        let rpc = try EVMRPC(transport: stub, url: #require(URL(string: "https://rpc.example.com")))
        return try TempoChannelSession(
            privateKey: privateKey, escrow: address(0x55), token: address(0x22),
            payee: address(0x33), salt: salt, fee: fee, chainID: chainID, rpc: rpc,
            pollInterval: .zero, maxPollAttempts: 1
        )
    }

    @Test("open reads back the deposit and marks the channel open")
    func openTracksDeposit() async throws {
        let session = try makeSession(deposit: 1000, finalized: false)
        let state = try await session.open(deposit: "1000")
        #expect(state.isOpen)
        #expect(!state.isFinalized)
        #expect(state.deposit == ChannelAmount(1000))
        #expect(state.cumulativeAmount == .zero)
    }

    @Test("vouchers must strictly increase and stay within the deposit")
    func voucherValidation() async throws {
        let session = try makeSession(deposit: 1000, finalized: false)
        _ = try await session.open(deposit: "1000")

        let first = try await session.voucher(cumulativeAmount: "400")
        #expect(first.cumulativeAmount == "400")
        #expect(first.signature.count == 65)
        #expect(first.channelID == session.channelID)

        // Strictly increasing.
        _ = try await session.voucher(cumulativeAmount: "700")
        await #expect(throws: TempoChannelSessionError.nonMonotonicVoucher) {
            _ = try await session.voucher(cumulativeAmount: "700") // equal, not greater
        }
        await #expect(throws: TempoChannelSessionError.nonMonotonicVoucher) {
            _ = try await session.voucher(cumulativeAmount: "500") // less
        }
        // Within the deposit.
        await #expect(throws: TempoChannelSessionError.voucherExceedsDeposit) {
            _ = try await session.voucher(cumulativeAmount: "2000")
        }
        let state = try await session.state()
        #expect(state.cumulativeAmount == ChannelAmount(700)) // unchanged by the rejects
    }

    @Test("operations before open are rejected")
    func guardsBeforeOpen() async throws {
        let session = try makeSession(deposit: 1000, finalized: false)
        await #expect(throws: TempoChannelSessionError.notOpen) {
            _ = try await session.voucher(cumulativeAmount: "1")
        }
        await #expect(throws: TempoChannelSessionError.notOpen) {
            _ = try await session.topUp(additionalDeposit: "1")
        }
        await #expect(throws: TempoChannelSessionError.notOpen) {
            _ = try await session.close()
        }
    }

    @Test("a second open is rejected")
    func doubleOpenRejected() async throws {
        let session = try makeSession(deposit: 1000, finalized: false)
        _ = try await session.open(deposit: "1000")
        await #expect(throws: TempoChannelSessionError.alreadyOpen) {
            _ = try await session.open(deposit: "1000")
        }
    }

    @Test("close finalizes and then rejects further operations")
    func closeFinalizes() async throws {
        let session = try makeSession(deposit: 1000, finalized: true)
        _ = try await session.open(deposit: "1000")
        _ = try await session.voucher(cumulativeAmount: "500")
        let closed = try await session.close()
        #expect(closed.isFinalized)
        await #expect(throws: TempoChannelSessionError.alreadyFinalized) {
            _ = try await session.voucher(cumulativeAmount: "600")
        }
    }

    @Test("a concurrent operation is rejected while one is in flight")
    func reentrancyGuard() async throws {
        let gate = SendGate()
        let stub = StubRPC(channelDeposit: 1000, channelFinalized: false, gate: gate)
        let rpc = try EVMRPC(transport: stub, url: #require(URL(string: "https://rpc.example.com")))
        let session = try TempoChannelSession(
            privateKey: privateKey, escrow: address(0x55), token: address(0x22),
            payee: address(0x33), salt: salt, fee: fee, chainID: chainID, rpc: rpc,
            pollInterval: .zero, maxPollAttempts: 1
        )
        // op1 enters open() (sets the in-flight guard) and parks at its first RPC send.
        let op1 = Task { try await session.open(deposit: "1000") }
        await gate.awaitParked()
        // op2 starts while op1 holds the session: the guard rejects it (actor reentrancy
        // would otherwise let it interleave at op1's await and collide on the nonce).
        await #expect(throws: TempoChannelSessionError.operationInProgress) {
            _ = try await session.open(deposit: "1000")
        }
        await gate.release()
        let state = try await op1.value
        #expect(state.isOpen)
    }

    @Test("an invalid signing key is rejected at init")
    func invalidKeyRejected() throws {
        let stub = StubRPC(channelDeposit: 0, channelFinalized: false)
        let rpc = try EVMRPC(transport: stub, url: #require(URL(string: "https://rpc.example.com")))
        #expect(throws: TempoChannelSessionError.invalidSigningKey) {
            _ = try TempoChannelSession(
                privateKey: Data(repeating: 0x11, count: 31), escrow: address(0x55),
                token: address(0x22), payee: address(0x33), salt: salt, fee: fee,
                chainID: chainID, rpc: rpc
            )
        }
    }
}

/// A method-aware JSON-RPC stub: succeeds every send/receipt/nonce read and reports a
/// fixed channel (`deposit`, `finalized`) for `eth_call` (getChannel).
private final class StubRPC: MPPHTTPTransport, @unchecked Sendable {
    private let channelDeposit: UInt64
    private let channelFinalized: Bool
    private let gate: SendGate?
    private let fakeHash = "0x" + String(repeating: "a", count: 64)

    init(channelDeposit: UInt64, channelFinalized: Bool, gate: SendGate? = nil) {
        self.channelDeposit = channelDeposit
        self.channelFinalized = channelFinalized
        self.gate = gate
    }

    func send(_: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        if let gate { await gate.gate() } // parks the first send (for the reentrancy test)
        let method = (try? JSONDecoder().decode(JSONValue.self, from: body))
            .flatMap { value -> String? in
                guard case let .object(fields) = value, case let .string(method)? = fields["method"]
                else { return nil }
                return method
            } ?? ""
        let result: String
        switch method {
        case "eth_getTransactionCount": result = "0x0"
        case "eth_sendRawTransaction": result = fakeHash
        case "eth_getTransactionReceipt":
            let receipt = #"{"status":"0x1","transactionHash":"\#(fakeHash)","blockNumber":"0x1"}"#
            return ok(rawResult: receipt)
        case "eth_call": result = getChannelHex()
        default: result = "0x0"
        }
        return ok(result: result)
    }

    private func ok(result: String) -> (HTTPResponse, Data) {
        ok(rawResult: "\"\(result)\"")
    }

    private func ok(rawResult: String) -> (HTTPResponse, Data) {
        let json = #"{"jsonrpc":"2.0","id":1,"result":\#(rawResult)}"#
        return (HTTPResponse(status: .init(code: 200)), Data(json.utf8))
    }

    /// The eight static 32-byte ABI words `getChannel` returns: finalized, closeRequestedAt,
    /// payer, payee, token, authorizedSigner, deposit, settled.
    private func getChannelHex() -> String {
        func word(_ low: UInt64) -> String {
            String(format: "%064x", low)
        }
        let finalized = word(channelFinalized ? 1 : 0)
        let zero = word(0)
        let deposit = word(channelDeposit)
        return "0x" + finalized + zero + zero + zero + zero + zero + deposit + zero
    }
}

/// A one-shot gate used by the reentrancy test: the stub `await`s `gate()` on its first
/// send, which signals `awaitParked` and then suspends until `release()`. Lets the test
/// hold one session operation mid-flight while it starts a second.
private actor SendGate {
    private var armed = true
    private var parked = false
    private var released = false
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /// Called by the stub. Parks only the first time; later calls pass through.
    func gate() async {
        guard armed else { return }
        armed = false
        parked = true
        parkedContinuation?.resume()
        parkedContinuation = nil
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    /// Resumes once the gated send has parked.
    func awaitParked() async {
        if parked { return }
        await withCheckedContinuation { parkedContinuation = $0 }
    }

    /// Releases the parked send.
    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
