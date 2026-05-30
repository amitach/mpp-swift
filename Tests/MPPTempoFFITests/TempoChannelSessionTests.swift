import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo
@testable import MPPTempoFFI

// Hermetic coverage of the channel-session state machine + validation, driven by a
// method-aware stub transport (no network). The full happy path against the real chain is
// in ModeratoE2ETests (gated). Here we exercise the guards and the off-chain voucher logic
// the live happy path does not: lifecycle ordering, monotonic + over-deposit voucher
// rejection, a reverted broadcast, and the reentrancy guard.

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

    private func makeSession(stub: StubRPC) throws -> TempoChannelSession {
        let rpc = try EVMRPC(transport: stub, url: #require(URL(string: "https://rpc.example.com")))
        return try TempoChannelSession(
            privateKey: privateKey, escrow: address(0x55), token: address(0x22),
            payee: address(0x33), salt: salt, fee: fee, chainID: chainID, rpc: rpc
        )
    }

    @Test("open tracks the deposit from the confirmed amount and marks the channel open")
    func openTracksDeposit() async throws {
        let session = try makeSession(stub: StubRPC())
        let state = try await session.open(deposit: "1000")
        #expect(state.isOpen)
        #expect(!state.isFinalized)
        #expect(state.deposit == ChannelAmount(1000))
        #expect(state.cumulativeAmount == .zero)
    }

    @Test("topUp adds to the tracked deposit")
    func topUpAddsDeposit() async throws {
        let session = try makeSession(stub: StubRPC())
        _ = try await session.open(deposit: "1000")
        let state = try await session.topUp(additionalDeposit: "500")
        #expect(state.deposit == ChannelAmount(1500))
    }

    @Test("vouchers must strictly increase and stay within the deposit")
    func voucherValidation() async throws {
        let session = try makeSession(stub: StubRPC())
        _ = try await session.open(deposit: "1000")

        let first = try await session.voucher(cumulativeAmount: "400")
        #expect(first.cumulativeAmount == "400")
        #expect(first.signature.count == 65)
        #expect(first.channelID == session.channelID)

        _ = try await session.voucher(cumulativeAmount: "700")
        await #expect(throws: TempoChannelSessionError.nonMonotonicVoucher) {
            _ = try await session.voucher(cumulativeAmount: "700") // equal, not greater
        }
        await #expect(throws: TempoChannelSessionError.nonMonotonicVoucher) {
            _ = try await session.voucher(cumulativeAmount: "500") // less
        }
        await #expect(throws: TempoChannelSessionError.voucherExceedsDeposit) {
            _ = try await session.voucher(cumulativeAmount: "2000")
        }
        let state = try await session.state()
        #expect(state.cumulativeAmount == ChannelAmount(700)) // unchanged by the rejects
    }

    @Test("operations before open are rejected")
    func guardsBeforeOpen() async throws {
        let session = try makeSession(stub: StubRPC())
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
        let session = try makeSession(stub: StubRPC())
        _ = try await session.open(deposit: "1000")
        await #expect(throws: TempoChannelSessionError.alreadyOpen) {
            _ = try await session.open(deposit: "1000")
        }
    }

    @Test("close finalizes and then rejects further operations")
    func closeFinalizes() async throws {
        let session = try makeSession(stub: StubRPC())
        _ = try await session.open(deposit: "1000")
        _ = try await session.voucher(cumulativeAmount: "500")
        let closed = try await session.close()
        #expect(closed.isFinalized)
        await #expect(throws: TempoChannelSessionError.alreadyFinalized) {
            _ = try await session.voucher(cumulativeAmount: "600")
        }
    }

    @Test("a reverted broadcast surfaces as transactionReverted")
    func revertedBroadcast() async throws {
        let session = try makeSession(stub: StubRPC(reverts: true))
        await #expect(throws: TempoChannelSessionError.transactionReverted("0x" + String(
            repeating: "a",
            count: 64
        ))) {
            _ = try await session.open(deposit: "1000")
        }
        // The op did not take effect; the channel is still openable (no poison).
        let state = try await session.state()
        #expect(!state.isOpen)
    }

    @Test("a concurrent operation is rejected while one is in flight")
    func reentrancyGuard() async throws {
        let gate = SendGate()
        let session = try makeSession(stub: StubRPC(gate: gate))
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
        let rpc = try EVMRPC(
            transport: StubRPC(),
            url: #require(URL(string: "https://rpc.example.com"))
        )
        #expect(throws: TempoChannelSessionError.invalidSigningKey) {
            _ = try TempoChannelSession(
                privateKey: Data(repeating: 0x11, count: 31), escrow: address(0x55),
                token: address(0x22), payee: address(0x33), salt: salt,
                fee: fee, chainID: chainID, rpc: rpc
            )
        }
    }
}

/// A method-aware JSON-RPC stub for the session: answers the nonce read and
/// `eth_sendRawTransactionSync` (with a success or reverted receipt). An optional gate
/// parks the first send (for the reentrancy test).
private final class StubRPC: MPPHTTPTransport, @unchecked Sendable {
    private let reverts: Bool
    private let gate: SendGate?
    private let fakeHash = "0x" + String(repeating: "a", count: 64)

    init(reverts: Bool = false, gate: SendGate? = nil) {
        self.reverts = reverts
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
        switch method {
        case "eth_getTransactionCount": return ok(rawResult: "\"0x0\"")
        case "eth_sendRawTransactionSync":
            let status = reverts ? "0x0" : "0x1"
            let head = #"{"status":"\#(status)","transactionHash":"\#(fakeHash)""#
            return ok(rawResult: head + #","blockNumber":"0x1"}"#)
        default: return ok(rawResult: "\"0x0\"")
        }
    }

    private func ok(rawResult: String) -> (HTTPResponse, Data) {
        let json = #"{"jsonrpc":"2.0","id":1,"result":\#(rawResult)}"#
        return (HTTPResponse(status: .init(code: 200)), Data(json.utf8))
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

    func gate() async {
        guard armed else { return }
        armed = false
        parked = true
        parkedContinuation?.resume()
        parkedContinuation = nil
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func awaitParked() async {
        if parked { return }
        await withCheckedContinuation { parkedContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
