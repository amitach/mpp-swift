import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM

/// A minimal Ethereum JSON-RPC client for reading from and broadcasting to the
/// Tempo chain, built over the shared ``MPPHTTPTransport`` seam (the same currency
/// type as the 402 flow: URLSession on Apple, async-http-client on Linux).
///
/// It performs only the JSON-RPC round-trip and carries no key material or payment
/// logic. The escrow ABI (call-data encode/decode) sits above it, and the bespoke
/// Tempo `0x76` transaction layer (which builds the raw bytes passed to
/// ``sendRawTransaction(_:)``) is the separate FFI workstream. The blob-free reads
/// (``call(to:data:)``, ``transactionReceipt(_:)``) are all a server needs.
public struct EVMRPC: Sendable {
    private let transport: any MPPHTTPTransport
    private let url: URL

    /// Creates a client that posts JSON-RPC to `url` over `transport`.
    ///
    /// Enforces the shared transport-security policy (``TransportSecurity``):
    /// `https`-only, unless `allowInsecureLocal` permits a loopback host (for a
    /// local test node). The RPC URL carries raw signed transactions, so a plain
    /// `http` endpoint is rejected up front rather than per call.
    public init(
        transport: any MPPHTTPTransport, url: URL, allowInsecureLocal: Bool = false
    ) throws(EVMRPCError) {
        guard TransportSecurity.isAllowed(
            scheme: url.scheme, host: url.host, allowInsecureLocal: allowInsecureLocal
        ) else {
            throw .insecureTransport(url: url.absoluteString)
        }
        self.transport = transport
        self.url = url
    }

    // MARK: - Typed calls

    /// `eth_call` against the latest block: invokes `data` on `to` and returns the
    /// raw return bytes (for an escrow read like `getChannel`). No state change.
    public func call(to address: EthereumAddress, data: Data) async throws(EVMRPCError) -> Data {
        let result = try await request("eth_call", params: .array([
            .object(["to": .string(address.bytes.hexPrefixed), "data": .string(data.hexPrefixed)]),
            .string("latest"),
        ]))
        return try hexData(result)
    }

    /// `eth_sendRawTransaction`: broadcasts an already-signed raw transaction and
    /// returns its `0x`-prefixed transaction hash. The raw bytes come from the
    /// `0x76` transaction builder (FFI), never from this layer.
    public func sendRawTransaction(_ raw: Data) async throws(EVMRPCError) -> String {
        let result = try await request("eth_sendRawTransaction", params: .array([
            .string(raw.hexPrefixed),
        ]))
        return try hexString(result)
    }

    /// `eth_getTransactionReceipt`: the receipt for `txHash`, or `nil` while the
    /// transaction is still pending (the node returns JSON `null`).
    public func transactionReceipt(
        _ txHash: String
    ) async throws(EVMRPCError) -> TransactionReceipt? {
        let result = try await request("eth_getTransactionReceipt", params: .array([
            .string(txHash),
        ]))
        if case .null = result { return nil }
        guard case let .object(fields) = result else {
            throw .malformedResponse("receipt is not an object")
        }
        guard case let .string(statusHex)? = fields["status"] else {
            throw .malformedResponse("receipt has no status")
        }
        guard case let .string(hash)? = fields["transactionHash"] else {
            throw .malformedResponse("receipt has no transactionHash")
        }
        var blockNumber: UInt64?
        if case let .string(blockHex)? = fields["blockNumber"] {
            blockNumber = UInt64(hexQuantity: blockHex)
        }
        return TransactionReceipt(
            transactionHash: hash,
            // EVM status is `0x1` (success) or `0x0` (reverted).
            succeeded: UInt64(hexQuantity: statusHex) == 1,
            blockNumber: blockNumber
        )
    }

    // MARK: - Core

    /// A single JSON-RPC call: encodes the `2.0` envelope, posts it over the
    /// transport, and returns the `result`, throwing on a JSON-RPC `error`, a
    /// non-2xx status, or a malformed response.
    public func request(
        _ method: String, params: JSONValue
    ) async throws(EVMRPCError) -> JSONValue {
        let body: Data
        do {
            body = try JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": .integer(1),
                "method": .string(method),
                "params": params,
            ]))
        } catch {
            throw .encodingFailed(String(describing: error))
        }

        let response: HTTPResponse
        let data: Data
        do {
            (response, data) = try await transport.send(httpRequest(), body: body)
        } catch {
            throw .transport(String(describing: error))
        }
        guard (200 ..< 300).contains(response.status.code) else {
            throw .httpStatus(response.status.code)
        }

        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw .malformedResponse(String(describing: error))
        }
        guard case let .object(envelope) = decoded else {
            throw .malformedResponse("response is not a JSON object")
        }
        if case let .object(error)? = envelope["error"] {
            var code = 0
            if case let .integer(value)? = error["code"] { code = Int(value) }
            var message = ""
            if case let .string(value)? = error["message"] { message = value }
            throw .rpc(code: code, message: message)
        }
        guard let result = envelope["result"] else {
            throw .malformedResponse("response has neither result nor error")
        }
        return result
    }

    // MARK: - Helpers

    /// Builds the POST request to the RPC URL from its components (scheme, authority
    /// with port, path), so only `HTTPTypes` is needed, not Foundation bridging.
    private func httpRequest() -> HTTPRequest {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        let authority = url.port.map { "\(url.host ?? ""):\($0)" } ?? url.host
        // Preserve the query (some RPC endpoints carry an API key there); default an
        // empty path to "/".
        let basePath = url.path.isEmpty ? "/" : url.path
        let path = url.query.map { "\(basePath)?\($0)" } ?? basePath
        return HTTPRequest(
            method: .post,
            scheme: url.scheme ?? "https",
            authority: authority,
            path: path,
            headerFields: fields
        )
    }

    private func hexString(_ value: JSONValue) throws(EVMRPCError) -> String {
        guard case let .string(string) = value else {
            throw .malformedResponse("result is not a string")
        }
        return string
    }

    private func hexData(_ value: JSONValue) throws(EVMRPCError) -> Data {
        let string = try hexString(value)
        guard let data = Data(hexPrefixed: string) else {
            throw .malformedResponse("result is not 0x-hex")
        }
        return data
    }
}

/// The decoded fields of an `eth_getTransactionReceipt` result that the channel
/// layer needs: the hash, whether it succeeded, and the block it landed in.
public struct TransactionReceipt: Sendable, Hashable {
    public let transactionHash: String
    /// `true` when the on-chain status is `0x1` (success), `false` on a revert.
    public let succeeded: Bool
    public let blockNumber: UInt64?

    public init(transactionHash: String, succeeded: Bool, blockNumber: UInt64?) {
        self.transactionHash = transactionHash
        self.succeeded = succeeded
        self.blockNumber = blockNumber
    }
}

/// A reason a JSON-RPC call failed.
public enum EVMRPCError: Error, Sendable, Hashable {
    /// The request envelope could not be JSON-encoded.
    case encodingFailed(String)
    /// The underlying HTTP transport threw (connection, TLS, timeout).
    case transport(String)
    /// The node returned a non-2xx HTTP status.
    case httpStatus(Int)
    /// The response was not a JSON-RPC object, or a typed result had the wrong shape.
    case malformedResponse(String)
    /// The node returned a JSON-RPC `error` member.
    case rpc(code: Int, message: String)
    /// The RPC URL was not `https` and `allowInsecureLocal` did not permit it.
    case insecureTransport(url: String)
}

private extension UInt64 {
    /// Parses a `0x`-prefixed hex quantity (e.g. a block number or status), or `nil`
    /// if it is not `0x`-hex or overflows. Per the JSON-RPC `QUANTITY` encoding.
    init?(hexQuantity string: String) {
        let head = string.prefix(2)
        guard head == "0x" || head == "0X" else { return nil }
        let digits = string.dropFirst(2)
        guard !digits.isEmpty else { return nil }
        self.init(digits, radix: 16)
    }
}
