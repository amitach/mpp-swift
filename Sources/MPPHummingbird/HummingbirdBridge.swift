import Foundation
import HTTPTypes
import Hummingbird
import MPPCore
import NIOCore

/// Bridges a Hummingbird `Request`/`Response` to the engine's framework-neutral
/// `(HTTPRequest, Data)` currency types.
///
/// A Hummingbird `Request` already exposes its request line + headers as a `swift-http-types`
/// `HTTPRequest` (`request.head`), so the only work is collecting the streamed request body into a
/// `Data` (bounded by `maxBodyBytes`) and wrapping the engine's response bytes back into a
/// `ResponseBody`. Both ``MPPProxy`` and a single ``MPPServerMiddleware`` route flow through this
/// one
/// seam so the body-collection and type mapping live in exactly one place.
@available(macOS 14, iOS 17, tvOS 17, visionOS 1, *)
enum HummingbirdBridge {
    /// Collects `request`'s body (up to `maxBodyBytes`), runs `handle` over the request head +
    /// body,
    /// and wraps the result as a Hummingbird `Response`.
    static func respond(
        to request: inout Request,
        maxBodyBytes: Int,
        _ handle: (HTTPRequest, Data) async -> (HTTPResponse, Data)
    ) async throws -> Response {
        let buffer = try await request.collectBody(upTo: maxBodyBytes)
        let body = Data(buffer.readableBytesView)
        let (head, responseBody) = await handle(request.head, body)
        return Response(
            status: head.status,
            headers: head.headerFields,
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: responseBody))
        )
    }
}
