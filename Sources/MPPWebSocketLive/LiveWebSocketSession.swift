import Foundation
import Logging
import MPPCore
import MPPWebSocket
import WSClient
import WSCore

// The default max collated inbound message is 1 MiB (`1 << 20`): session control frames and
// streamed chunks are small, so the cap only bounds a hostile peer. Inlined as a default argument
// (a public default cannot reference a private constant).

/// A ``SessionSocketWriter`` over a live ``WebSocketOutboundWriter``. Session frames go out as
/// text frames; `close` finishes the bridged inbound stream so the orchestration loop returns,
/// which ends the connection's handler and closes the socket (a `WebSocketOutboundWriter` exposes
/// no explicit close, and the session protocol closes by ending the handler).
///
/// `@unchecked Sendable`: ``SessionWebSocketServer`` / ``SessionWebSocketClient`` funnel every
/// `send` through one actor, so the wrapped outbound writer is never touched concurrently; the
/// continuation is itself `Sendable`.
private final class WSCoreSessionSocketWriter: SessionSocketWriter, @unchecked Sendable {
    private let outbound: WebSocketOutboundWriter
    private let inboundContinuation: AsyncStream<String>.Continuation

    init(outbound: WebSocketOutboundWriter, inboundContinuation: AsyncStream<String>.Continuation) {
        self.outbound = outbound
        self.inboundContinuation = inboundContinuation
    }

    func send(_ text: String) async throws {
        try await outbound.write(.text(text))
    }

    func close(code _: UInt16, reason _: String) async {
        inboundContinuation.finish()
    }
}

/// The bridged inbound for one session: the text stream the orchestrators read, the continuation
/// (shared with the writer so `close` can end it), and the pump task to cancel when done.
private struct InboundBridge {
    let stream: AsyncStream<String>
    let continuation: AsyncStream<String>.Continuation
    let pump: Task<Void, Never>
}

/// Bridges a socket's inbound text messages into an `AsyncStream<String>` the orchestrators read,
/// finishing the stream when inbound ends.
private func bridgeInbound(_ inbound: WebSocketInboundStream, maxFrameSize: Int) -> InboundBridge {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    let pump = Task {
        do {
            for try await message in inbound.messages(maxSize: maxFrameSize) {
                if case let .text(text) = message { continuation.yield(text) }
            }
        } catch {
            // Inbound failed (closed/protocol error); fall through to finish the bridged stream.
        }
        continuation.finish()
    }
    return InboundBridge(stream: stream, continuation: continuation, pump: pump)
}

/// The live server side: serve one metered session over an upgraded WebSocket. A host wires this
/// inside its WebSocket upgrade handler (e.g. Hummingbird's `http1WebSocketUpgrade`), passing the
/// `inbound`/`outbound` the upgrade yields plus the same verify / makeStream / closeReceipt seams
/// ``SessionWebSocketServer`` takes. Returns when the session closes.
public enum WebSocketSessionServer {
    /// Serves one metered session over the upgraded socket's `inbound`/`outbound`, bridging them
    /// into ``SessionWebSocketServer``. Returns when the session closes.
    public static func serve(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        verify: @escaping SessionWebSocketServer.Verify,
        makeStream: @escaping SessionWebSocketServer.MakeStream,
        closeReceipt: @escaping SessionWebSocketServer.CloseReceipt,
        maxFrameSize: Int = 1 << 20
    ) async {
        let bridge = bridgeInbound(inbound, maxFrameSize: maxFrameSize)
        let writer = WSCoreSessionSocketWriter(
            outbound: outbound, inboundContinuation: bridge.continuation
        )
        await SessionWebSocketServer.serve(
            inbound: bridge.stream, writer: writer,
            verify: verify, makeStream: makeStream, closeReceipt: closeReceipt
        )
        bridge.pump.cancel()
    }
}

/// The live client side: connect to a session endpoint and consume the metered stream to its
/// terminal receipt. Wraps ``SessionWebSocketClient`` over a real ``WebSocketClient`` connection.
public enum WebSocketSessionClient {
    /// Connects to `url`, runs the session, and returns the terminal `payment-close-ready` receipt
    /// (throwing ``SessionWebSocketClient/ClientError`` on a rejection / premature close).
    public static func run(
        url: String,
        authorization: String,
        makeVoucher: @escaping SessionWebSocketClient.MakeVoucher,
        handlers: SessionWebSocketClient.Handlers = .init(),
        logger: Logger,
        configuration: WebSocketClientConfiguration = .init(),
        maxFrameSize: Int = 1 << 20
    ) async throws -> Receipt {
        let outcome = OutcomeBox()
        do {
            _ = try await WebSocketClient.connect(
                url: url, configuration: configuration, logger: logger
            ) { inbound, outbound, _ in
                let bridge = bridgeInbound(inbound, maxFrameSize: maxFrameSize)
                let writer = WSCoreSessionSocketWriter(
                    outbound: outbound, inboundContinuation: bridge.continuation
                )
                do {
                    let receipt = try await SessionWebSocketClient.run(
                        inbound: bridge.stream, writer: writer, authorization: authorization,
                        makeVoucher: makeVoucher, handlers: handlers
                    )
                    outcome.set(.success(receipt))
                } catch {
                    outcome.set(.failure(error))
                }
                bridge.pump.cancel()
            }
        } catch {
            // The captured session result is authoritative. Once the session produced an outcome,
            // a connection-level teardown error (e.g. a CancellationError when the peer closes the
            // socket, which NIOPosix and NIOTransportServices surface differently) is not the
            // session's result. Propagate the connect error only if the session never produced one.
            if !outcome.isSet { throw error }
        }
        return try outcome.take()
    }
}

/// A thread-safe slot for the session outcome captured inside the connection handler.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Receipt, any Error>?

    func set(_ value: Result<Receipt, any Error>) {
        lock.withLock { if outcome == nil { outcome = value } }
    }

    var isSet: Bool {
        lock.withLock { outcome != nil }
    }

    func take() throws -> Receipt {
        switch lock.withLock({ outcome }) {
        case let .success(receipt): return receipt
        case let .failure(error): throw error
        case .none: throw SessionWebSocketClient.ClientError.closedWithoutReceipt
        }
    }
}
