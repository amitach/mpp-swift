import Foundation
import MPPCore
import MPPTempoServer

/// Consumes a metered Tempo session over a WebSocket, the client counterpart of
/// ``SessionWebSocketServer``: it sends the initial `authorization` credential, then reads
/// the in-band ``SessionWebSocketFrame`` stream, auto-answering each
/// `payment-need-voucher` with a higher voucher so the stream keeps flowing, surfacing
/// `message` chunks and `payment-receipt`s, and returning the terminal
/// `payment-close-ready` receipt.
///
/// Like the server, it is decoupled from the channel/credential machinery: the caller
/// supplies the initial authorization and a ``MakeVoucher`` that signs a higher cumulative
/// voucher for a shortfall (the host wires this to `TempoChannelMethod`). To close early,
/// the caller can send a `payment-close-request` frame through the same writer; ``run``
/// then receives the resulting `payment-close-ready` and returns it.
public enum SessionWebSocketClient {
    /// Builds the `Authorization` header value for the higher voucher a shortfall needs.
    public typealias MakeVoucher = @Sendable (SessionStreamEvent.NeedVoucher) async throws -> String

    /// Why a session ended other than with a `payment-close-ready` receipt.
    public enum ClientError: Error, Sendable, Hashable {
        /// The server sent a `payment-error` frame (an HTTP-style status and message).
        case rejected(status: Int, message: String)
        /// The socket's inbound ended before any terminal `payment-close-ready` arrived.
        case closedWithoutReceipt
    }

    /// Side-effect sinks for the frames a caller usually wants to observe.
    public struct Handlers: Sendable {
        /// A streamed application-data chunk (`message`).
        public var onMessage: @Sendable (String) -> Void
        /// Each settlement receipt the server echoes for an authorization/voucher.
        public var onReceipt: @Sendable (Receipt) -> Void

        public init(
            onMessage: @escaping @Sendable (String) -> Void = { _ in },
            onReceipt: @escaping @Sendable (Receipt) -> Void = { _ in }
        ) {
            self.onMessage = onMessage
            self.onReceipt = onReceipt
        }
    }

    /// Runs the session to completion: sends `authorization`, then drains `inbound` until a
    /// `payment-close-ready` (returned) or a `payment-error` (thrown). A
    /// `payment-need-voucher` is answered in-line with a fresh `authorization` voucher from
    /// `makeVoucher`. Throws ``ClientError/closedWithoutReceipt`` if the socket closes first.
    public static func run(
        inbound: AsyncStream<String>,
        writer: any SessionSocketWriter,
        authorization: String,
        makeVoucher: @escaping MakeVoucher,
        handlers: Handlers = .init()
    ) async throws -> Receipt {
        try await writer.send(SessionWebSocketFrame.authorization(authorization).encoded())
        for await text in inbound {
            guard let frame = SessionWebSocketFrame.parse(text) else { continue }
            switch frame {
            case let .message(data):
                handlers.onMessage(data)
            case let .receipt(receipt):
                handlers.onReceipt(receipt)
            case let .needVoucher(need):
                let voucher = try await makeVoucher(need)
                try await writer.send(SessionWebSocketFrame.authorization(voucher).encoded())
            case let .closeReady(receipt):
                return receipt
            case let .error(status, message):
                throw ClientError.rejected(status: status, message: message)
            // Client-to-server frames are never expected inbound; ignore them.
            case .authorization, .closeRequest:
                continue
            }
        }
        throw ClientError.closedWithoutReceipt
    }
}
