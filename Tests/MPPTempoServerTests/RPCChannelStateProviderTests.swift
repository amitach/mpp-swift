import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import MPPTempo
import Testing
@testable import MPPTempoServer

// RPCChannelStateProvider over a method-routing transport stub: read delegation,
// broadcast-relay + receipt polling, settle via the injected close-tx builder, and
// the revert / receipt-timeout failure paths. No network.

/// A stub MPPHTTPTransport that answers each JSON-RPC method from a fixed map and
/// records what was broadcast / how many times the receipt was polled.
private final class RoutingStub: MPPHTTPTransport, @unchecked Sendable {
    /// method -> the raw JSON text to place in `result` (quoted for a string).
    var results: [String: String]
    private(set) var sentRawTx: String?
    private(set) var receiptPolls = 0
    init(_ results: [String: String]) {
        self.results = results
    }

    func send(_: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        guard case let .object(envelope) = decoded,
              case let .string(method)? = envelope["method"]
        else { return (HTTPResponse(status: .badRequest), Data()) }
        if method == "eth_sendRawTransaction", case let .array(params)? = envelope["params"],
           case let .string(raw)? = params.first {
            sentRawTx = raw
        }
        if method == "eth_getTransactionReceipt" { receiptPolls += 1 }
        let result = results[method] ?? "null"
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":\#(result)}"#.utf8)
        return (HTTPResponse(status: .ok), body)
    }
}

/// A close-tx builder that returns fixed bytes and records that it was called.
private final class StubCloseBuilder: TempoCloseTxBuilder, @unchecked Sendable {
    let raw: Data
    private(set) var called = false
    init(_ raw: Data) {
        self.raw = raw
    }

    func buildCloseTransaction(
        voucher _: Voucher, signature _: Data, escrow _: EthereumAddress, chainID _: UInt64
    ) async throws -> Data {
        called = true
        return raw
    }
}

private let escrowAddr = { () -> EthereumAddress in
    guard let address = EthereumAddress(hex: "0x5555555555555555555555555555555555555555") else {
        preconditionFailure("bad address")
    }
    return address
}()

private let zeroChannelBlob = "\"0x" + String(repeating: "0", count: 512) + "\""
private let okReceipt = #"{"status":"0x1","transactionHash":"0xh","blockNumber":"0x1"}"#

private func makeProvider(
    _ stub: RoutingStub, builder: any TempoCloseTxBuilder = StubCloseBuilder(Data()),
    maxReceiptPolls: Int = 60
) throws -> RPCChannelStateProvider {
    let url = try #require(URL(string: "https://rpc.example.com"))
    let rpc = try EVMRPC(transport: stub, url: url)
    return RPCChannelStateProvider(
        rpc: rpc, closeTxBuilder: builder, maxReceiptPolls: maxReceiptPolls,
        pollInterval: .zero, sleep: { _ in } // no real delay in tests
    )
}

@Suite("RPCChannelStateProvider")
struct RPCChannelStateProviderTests {
    @Test("channelState delegates to the escrow getChannel read")
    func channelStateReads() async throws {
        let provider = try makeProvider(RoutingStub(["eth_call": zeroChannelBlob]))
        let channel = try await provider.channelState(
            channelID: Data(repeating: 0xAB, count: 32), escrow: escrowAddr, chainID: 42431
        )
        #expect(channel.deposit == .zero)
    }

    @Test("broadcastOpen relays the signed tx, waits for the receipt, then reads state")
    func broadcastOpenRelays() async throws {
        let stub = RoutingStub([
            "eth_sendRawTransaction": "\"0xopenhash\"",
            "eth_getTransactionReceipt": okReceipt,
            "eth_call": zeroChannelBlob,
        ])
        let provider = try makeProvider(stub)
        let raw = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let (state, txHash) = try await provider.broadcastOpen(
            serializedTransaction: raw, channelID: Data(repeating: 0xAB, count: 32),
            escrow: escrowAddr, chainID: 42431
        )
        #expect(txHash == "0xopenhash")
        #expect(stub.sentRawTx == raw.hexPrefixed)
        #expect(state.deposit == .zero)
    }

    @Test("a reverted broadcast throws transactionReverted")
    func broadcastReverted() async throws {
        let stub = RoutingStub([
            "eth_sendRawTransaction": "\"0xh\"",
            "eth_getTransactionReceipt": #"{"status":"0x0","transactionHash":"0xh"}"#,
        ])
        let provider = try makeProvider(stub)
        await #expect(throws: RPCProviderError.transactionReverted("0xh")) {
            try await provider.broadcastOpen(
                serializedTransaction: Data([0x01]), channelID: Data(repeating: 0xAB, count: 32),
                escrow: escrowAddr, chainID: 42431
            )
        }
    }

    @Test("a receipt that never appears throws receiptTimeout after the poll budget")
    func receiptTimeout() async throws {
        // No eth_getTransactionReceipt entry -> always null (pending).
        let stub = RoutingStub(["eth_sendRawTransaction": "\"0xh\""])
        let provider = try makeProvider(stub, maxReceiptPolls: 3)
        await #expect(throws: RPCProviderError.receiptTimeout("0xh")) {
            try await provider.broadcastOpen(
                serializedTransaction: Data([0x01]), channelID: Data(repeating: 0xAB, count: 32),
                escrow: escrowAddr, chainID: 42431
            )
        }
        #expect(stub.receiptPolls == 3)
    }

    @Test("settle builds the close tx via the seam and broadcasts those exact bytes")
    func settleBuildsAndBroadcasts() async throws {
        let closeBytes = Data([0x76, 0xCA, 0xFE])
        let builder = StubCloseBuilder(closeBytes)
        let stub = RoutingStub([
            "eth_sendRawTransaction": "\"0xsettlehash\"",
            "eth_getTransactionReceipt": okReceipt,
        ])
        let provider = try makeProvider(stub, builder: builder)
        let voucher = try #require(Voucher(
            channelID: Data(repeating: 0xAB, count: 32),
            cumulativeAmount: "100"
        ))
        let txHash = try await provider.settle(
            channelID: Data(repeating: 0xAB, count: 32), voucher: voucher,
            signature: Data(repeating: 0x01, count: 65), escrow: escrowAddr, chainID: 42431
        )
        #expect(txHash == "0xsettlehash")
        #expect(builder.called == true)
        #expect(stub.sentRawTx == closeBytes.hexPrefixed)
    }
}
