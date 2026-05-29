import Foundation
import HTTPTypes

/// The HTTP seam the 402 client flow runs over: send one request, get one
/// response. Kept deliberately minimal and framework-neutral (over
/// `apple/swift-http-types`, consistent with the server middleware) so the flow
/// logic is testable against an in-memory stub and the real network transports
/// (URLSession on Apple, async-http-client on Linux) are separate, swappable
/// conformances.
public protocol MPPHTTPTransport: Sendable {
    /// Sends `request` with `body` and returns the response and its body.
    ///
    /// Implementations perform no payment logic: the ``PaymentClient`` flow owns
    /// 402 detection, challenge selection, credential building, and the retry.
    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data)
}
