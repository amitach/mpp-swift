import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// EVMRPC over a stubbed MPPHTTPTransport: asserts the JSON-RPC envelope it posts and
// how it decodes results, errors, and HTTP failures. One network-gated smoke test
// exercises the real Moderato testnet (skipped unless MPP_MODERATO_E2E=1).

/// Records the posted request/body and returns a canned JSON-RPC response.
private final class StubHTTP: MPPHTTPTransport, @unchecked Sendable {
    var responseBody: Data
    var statusCode: Int
    private(set) var lastBody: Data?
    private(set) var lastRequest: HTTPRequest?
    init(json: String, statusCode: Int = 200) {
        responseBody = Data(json.utf8)
        self.statusCode = statusCode
    }

    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        lastRequest = request
        lastBody = body
        return (HTTPResponse(status: .init(code: statusCode)), responseBody)
    }
}

private func makeURL(_ string: String) -> URL {
    guard let url = URL(string: string) else { preconditionFailure("bad url \(string)") }
    return url
}

private func makeAddress(_ hex: String) -> EthereumAddress {
    guard let address = EthereumAddress(hex: hex) else { preconditionFailure("bad address \(hex)") }
    return address
}

private let rpcURL = makeURL("https://rpc.example.com")
private let addr = makeAddress("0x5555555555555555555555555555555555555555")

private func sentEnvelope(_ stub: StubHTTP) throws -> [String: JSONValue] {
    let body = try #require(stub.lastBody)
    guard case let .object(envelope) = try JSONDecoder().decode(JSONValue.self, from: body) else {
        throw EVMRPCError.malformedResponse("body not an object")
    }
    return envelope
}

@Suite("EVMRPC")
struct EVMRPCTests {
    @Test("eth_call posts the 2.0 envelope and decodes the 0x-hex result")
    func ethCall() async throws {
        let stub = StubHTTP(json: #"{"jsonrpc":"2.0","id":1,"result":"0x1234"}"#)
        let rpc = try EVMRPC(transport: stub, url: rpcURL)
        let result = try await rpc.call(to: addr, data: Data([0xAB, 0xCD]))
        #expect(result == Data([0x12, 0x34]))

        let envelope = try sentEnvelope(stub)
        #expect(envelope["jsonrpc"] == .string("2.0"))
        #expect(envelope["method"] == .string("eth_call"))
        guard case let .array(params)? = envelope["params"],
              case let .object(callObject) = params.first
        else { throw EVMRPCError.malformedResponse("params shape") }
        #expect(callObject["to"] == .string("0x5555555555555555555555555555555555555555"))
        #expect(callObject["data"] == .string("0xabcd"))
        #expect(params.last == .string("latest"))
    }

    @Test("eth_sendRawTransaction returns the transaction hash")
    func sendRaw() async throws {
        let hash = "0xabc0000000000000000000000000000000000000000000000000000000000001"
        let stub = StubHTTP(json: #"{"jsonrpc":"2.0","id":1,"result":"\#(hash)"}"#)
        let rpc = try EVMRPC(transport: stub, url: rpcURL)
        let returned = try await rpc.sendRawTransaction(Data([0xDE, 0xAD]))
        #expect(returned == hash)
        let envelope = try sentEnvelope(stub)
        #expect(envelope["method"] == .string("eth_sendRawTransaction"))
        #expect(envelope["params"] == .array([.string("0xdead")]))
    }

    @Test("a successful receipt decodes status, hash, and block number")
    func receiptSuccess() async throws {
        let stub = StubHTTP(json: #"""
        {"jsonrpc":"2.0","id":1,"result":{
          "status":"0x1","transactionHash":"0xfeed","blockNumber":"0x1a"
        }}
        """#)
        let rpc = try EVMRPC(transport: stub, url: rpcURL)
        let receipt = try #require(await rpc.transactionReceipt("0xfeed"))
        #expect(receipt.succeeded == true)
        #expect(receipt.transactionHash == "0xfeed")
        #expect(receipt.blockNumber == 26)
    }

    @Test("a reverted receipt reports succeeded == false")
    func receiptReverted() async throws {
        let stub = StubHTTP(json: #"""
        {"jsonrpc":"2.0","id":1,"result":{"status":"0x0","transactionHash":"0xfeed"}}
        """#)
        let rpc = try EVMRPC(transport: stub, url: rpcURL)
        let receipt = try #require(await rpc.transactionReceipt("0xfeed"))
        #expect(receipt.succeeded == false)
        #expect(receipt.blockNumber == nil)
    }

    @Test("a pending transaction (null result) yields nil, not an error")
    func receiptPending() async throws {
        let stub = StubHTTP(json: #"{"jsonrpc":"2.0","id":1,"result":null}"#)
        let rpc = try EVMRPC(transport: stub, url: rpcURL)
        let receipt = try await rpc.transactionReceipt("0xfeed")
        #expect(receipt == nil)
    }

    @Test("a JSON-RPC error member is surfaced as .rpc")
    func rpcError() async throws {
        let stub =
            StubHTTP(json: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nope"}}"#)
        let rpc = try EVMRPC(transport: stub, url: rpcURL)
        await #expect(throws: EVMRPCError.rpc(code: -32000, message: "nope")) {
            try await rpc.call(to: addr, data: Data())
        }
    }

    @Test("a non-2xx status throws .httpStatus before parsing")
    func httpFailure() async throws {
        let stub = StubHTTP(json: "upstream down", statusCode: 502)
        let rpc = try EVMRPC(transport: stub, url: rpcURL)
        await #expect(throws: EVMRPCError.httpStatus(502)) {
            try await rpc.call(to: addr, data: Data())
        }
    }

    @Test("a non-JSON body throws .malformedResponse")
    func malformedBody() async throws {
        let stub = StubHTTP(json: "<html>not json</html>")
        let rpc = try EVMRPC(transport: stub, url: rpcURL)
        await #expect(throws: EVMRPCError.self) {
            try await rpc.call(to: addr, data: Data())
        }
    }

    @Test("the URL query (e.g. an API key) is preserved in the posted request path")
    func preservesQuery() async throws {
        let stub = StubHTTP(json: #"{"jsonrpc":"2.0","id":1,"result":"0x"}"#)
        let rpc = try EVMRPC(transport: stub, url: makeURL("https://rpc.example.com/v2?key=secret"))
        _ = try await rpc.call(to: addr, data: Data())
        let path = try #require(stub.lastRequest?.path)
        #expect(path == "/v2?key=secret")
    }

    @Test("a non-https RPC URL is rejected up front")
    func rejectsInsecure() throws {
        #expect(throws: EVMRPCError.self) {
            _ = try EVMRPC(transport: StubHTTP(json: ""), url: makeURL("http://rpc.example.com"))
        }
    }

    @Test("a loopback http node is allowed only under allowInsecureLocal")
    func loopbackOptIn() throws {
        let url = makeURL("http://127.0.0.1:8545")
        #expect(throws: EVMRPCError.self) {
            _ = try EVMRPC(transport: StubHTTP(json: ""), url: url)
        }
        // Opt-in permits it (a local dev node).
        _ = try EVMRPC(transport: StubHTTP(json: ""), url: url, allowInsecureLocal: true)
    }

    @Test("live Moderato eth_chainId returns 42431", .enabled(if: liveEnabled))
    func liveModeratoChainID() async throws {
        let rpc = try EVMRPC(
            transport: URLSessionTransport(),
            url: #require(URL(string: "https://rpc.moderato.tempo.xyz"))
        )
        let result = try await rpc.request("eth_chainId", params: .array([]))
        guard case let .string(hex) = result else {
            throw EVMRPCError.malformedResponse("chainId not a string")
        }
        // 0xa5bf == 42431, the Moderato chain id.
        #expect(UInt64(hex.dropFirst(2), radix: 16) == 42431)
    }
}

/// Network smoke tests run only when explicitly enabled, so CI stays hermetic.
private let liveEnabled = ProcessInfo.processInfo.environment["MPP_MODERATO_E2E"] == "1"
