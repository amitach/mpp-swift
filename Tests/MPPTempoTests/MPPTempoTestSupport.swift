import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM

// Shared doubles + fixtures for the MPPTempo test target (one home, not per-file).

/// Records the posted request/body and returns a canned JSON-RPC response.
final class StubHTTP: MPPHTTPTransport, @unchecked Sendable {
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

func makeURL(_ string: String) -> URL {
    guard let url = URL(string: string) else { preconditionFailure("bad url \(string)") }
    return url
}

func makeAddress(_ hex: String) -> EthereumAddress {
    guard let address = EthereumAddress(hex: hex) else { preconditionFailure("bad address \(hex)") }
    return address
}
