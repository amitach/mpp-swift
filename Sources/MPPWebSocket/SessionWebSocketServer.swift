import Foundation
import MPPCore
import MPPTempoServer

/// Writes outbound text frames to a connected WebSocket and closes it. The transport
/// adapter (a live `hummingbird-websocket` socket, or an in-process pair in tests)
/// conforms this; ``SessionWebSocketServer`` funnels every send through one instance so
/// writes from the read loop and the streaming task never interleave on the wire.
public protocol SessionSocketWriter: Sendable {
    /// Send one text frame.
    func send(_ text: String) async throws
    /// Close the socket with a WebSocket close code and reason.
    func close(code: UInt16, reason: String) async
}

/// What a verified in-band `authorization` frame asks the server to do, mapped from the
/// session credential's channel action by the host (which owns ``MPPTempoServer``).
public enum SessionAuthKind: Sendable, Hashable {
    /// `open` / `voucher`: start the metered stream if it is not already running (a
    /// voucher just advances the channel; the running stream resumes on the new headroom).
    case stream
    /// `topUp`: acknowledge the receipt; do not stream.
    case ack
    /// `close`: acknowledge the (on-chain settled) receipt, then close the socket.
    case close
}

/// The outcome of verifying an in-band `authorization` frame: the settlement receipt to
/// echo back and what the credential's action asks of the session.
public struct SessionAuthorization: Sendable {
    public var receipt: Receipt
    public var kind: SessionAuthKind

    public init(receipt: Receipt, kind: SessionAuthKind) {
        self.receipt = receipt
        self.kind = kind
    }
}

/// A verification failure that maps to a `payment-error` frame: an HTTP-style status and
/// a client-safe message (e.g. a 402 for a rejected credential). Any other thrown error
/// is treated as an internal failure (status 500).
public struct SessionRejected: Error, Sendable, Hashable {
    public var status: Int
    public var message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

/// Bridges a WebSocket to a metered Tempo session, the transport sibling of the SSE
/// responder: the whole session rides in-band as ``SessionWebSocketFrame`` JSON frames.
///
/// The client sends `authorization` frames (the initial credential and, mid-stream, the
/// higher vouchers a `payment-need-voucher` asks for) and a `payment-close-request`; the
/// server verifies each authorization, echoes a `payment-receipt`, streams `message` /
/// `payment-need-voucher` frames metered against the channel, and ends with a
/// `payment-close-ready` carrying the settlement receipt (or a `payment-error`).
///
/// Three seams are injected so this orchestration stays decoupled from the channel store
/// and the on-chain method (which live in ``MPPTempoServer``): ``Verify`` routes an
/// authorization to a settlement receipt, ``MakeStream`` produces the metered event
/// stream once the session opens, and ``CloseReceipt`` snapshots the receipt for a
/// client-initiated close. The metering itself is
/// ``SessionStream/serve(store:target:options:next:)``.
public enum SessionWebSocketServer {
    /// Verifies one in-band `authorization` frame. Returns the receipt + action on success;
    /// throws ``SessionRejected`` (mapped to a `payment-error`) on a rejected credential.
    public typealias Verify = @Sendable (_ authorization: String) async throws
        -> SessionAuthorization
    /// Produces the metered event stream for the opened session (the host wires this to
    /// `SessionStream.serve` over its channel store and application chunk source).
    public typealias MakeStream = @Sendable () -> AsyncThrowingStream<SessionStreamEvent, any Error>
    /// Snapshots the current settlement receipt for a client-initiated close handshake.
    public typealias CloseReceipt = @Sendable () async throws -> Receipt

    /// Tuning for a served session.
    public struct Options: Sendable {
        public init() {}
    }

    /// Serves one session over `writer`, driven by the inbound text frames in `inbound`,
    /// until the socket closes. Inbound frames are processed in order; the read loop awaits
    /// each before reading the next, so the transport's own backpressure bounds in-flight
    /// work (the structural equivalent of the reference SDK's explicit queued-message cap,
    /// which is an artifact of its single-threaded runtime). The transport adapter bridges
    /// its socket's inbound text frames into `inbound` and finishes it when the socket
    /// closes. Returns when the session ends.
    public static func serve(
        inbound: AsyncStream<String>,
        writer: any SessionSocketWriter,
        verify: @escaping Verify,
        makeStream: @escaping MakeStream,
        closeReceipt: @escaping CloseReceipt,
        options: Options = .init()
    ) async {
        _ = options
        let session = Session(
            writer: writer, verify: verify, makeStream: makeStream, closeReceipt: closeReceipt
        )
        for await text in inbound {
            if await session.isClosed { break }
            guard let frame = SessionWebSocketFrame.parse(text) else { continue }
            await session.handle(frame)
        }
        await session.shutdown()
    }
}

/// WebSocket close codes used by the session handshake (RFC 6455).
private enum CloseCode {
    static let normal: UInt16 = 1000
    static let policyViolation: UInt16 = 1008
    static let internalError: UInt16 = 1011
}

/// Owns all per-session state and serializes every socket write. Actor isolation lets the
/// concurrent streaming task and the read loop both drive the socket without interleaving
/// or racing the close flags.
private actor Session {
    private let writer: any SessionSocketWriter
    private let verify: SessionWebSocketServer.Verify
    private let makeStream: SessionWebSocketServer.MakeStream
    private let closeReceipt: SessionWebSocketServer.CloseReceipt

    private var closed = false
    private var streamStarted = false
    private var closeRequested = false
    private var closeReadySent = false
    private var streamTask: Task<Void, Never>?

    init(
        writer: any SessionSocketWriter,
        verify: @escaping SessionWebSocketServer.Verify,
        makeStream: @escaping SessionWebSocketServer.MakeStream,
        closeReceipt: @escaping SessionWebSocketServer.CloseReceipt
    ) {
        self.writer = writer
        self.verify = verify
        self.makeStream = makeStream
        self.closeReceipt = closeReceipt
    }

    var isClosed: Bool {
        closed
    }

    func handle(_ frame: SessionWebSocketFrame) async {
        guard !closed else { return }
        switch frame {
        case let .authorization(authorization):
            await processAuthorization(authorization)
        case .closeRequest:
            await requestClose()
        // Server-to-client frames are never expected inbound; ignore them.
        case .message, .needVoucher, .receipt, .closeReady, .error:
            break
        }
    }

    /// Inbound channel ended (or the read loop broke) without an explicit close: cancel any
    /// running stream and close the socket if it is still open.
    func shutdown() async {
        guard !closed else { return }
        await close(code: CloseCode.normal, reason: "session ended")
    }

    private func processAuthorization(_ authorization: String) async {
        let outcome: SessionAuthorization
        do {
            outcome = try await verify(authorization)
        } catch let rejection as SessionRejected {
            await emit(.error(status: rejection.status, message: rejection.message))
            await close(code: CloseCode.policyViolation, reason: rejection.message)
            return
        } catch {
            // A cancellation here means the serve task was torn down (e.g. shutdown) while a verify
            // was in flight, not a verification failure: don't emit a spurious payment-error frame
            // (same cancellation-vs-error distinction as startStream's catch).
            if Task.isCancelled { return }
            await emit(.error(status: 500, message: "session verification failed"))
            await close(code: CloseCode.internalError, reason: "session verification failed")
            return
        }

        // The auth / voucher settlement receipt echoes back as `payment-receipt`; the
        // terminal stream receipt (below) is the distinct `payment-close-ready`.
        await emit(.receipt(outcome.receipt))

        switch outcome.kind {
        case .close:
            await close(code: CloseCode.normal, reason: "payment session closed")
        case .ack:
            return
        case .stream:
            guard !streamStarted, !closeRequested, !closed else { return }
            streamStarted = true
            startStream()
        }
    }

    private func startStream() {
        let stream = makeStream()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    if await isClosed { break }
                    switch event {
                    case .message, .needVoucher:
                        // `payment-need-voucher` pauses the metering loop until the client's
                        // next `authorization` voucher advances the channel; `message` is a chunk.
                        await emit(SessionWebSocketFrame(event))
                    case let .receipt(receipt):
                        // The stream's terminal receipt is the natural-end settlement: send it as
                        // `payment-close-ready` (not `payment-receipt`) and close.
                        await sendCloseReady(receipt)
                    }
                }
                // A cancelled stream means a client `payment-close-request` is driving the
                // handshake (`requestClose` sends close-ready and closes); do not also close here,
                // which would race that close and drop the close-ready.
                if Task.isCancelled { return }
                await finishStreamNormally()
            } catch {
                // The cancellation that a `payment-close-request` triggers surfaces HERE when the
                // metered stream finishes by throwing (production `SessionStream.serve` cancels its
                // poll loop and `finish(throwing: CancellationError)`). That is the close-request
                // path, not a session failure: `requestClose` owns the close-ready handshake, so
                // returning (vs `failStream`) avoids a spurious `payment-error` + close 1011 that
                // would also pre-empt the close-ready.
                if Task.isCancelled { return }
                await failStream(error)
            }
        }
    }

    /// The stream finished pulling chunks. If it never emitted a terminal receipt (it
    /// always does on a clean finish), close anyway so the socket never dangles.
    private func finishStreamNormally() async {
        guard !closed else { return }
        await close(code: CloseCode.normal, reason: "session complete")
    }

    private func failStream(_: any Error) async {
        guard !closed else { return }
        await emit(.error(status: 500, message: "websocket session failed"))
        await close(code: CloseCode.internalError, reason: "websocket session failed")
    }

    /// Client asked to close: stop metering, snapshot the receipt, send `payment-close-ready`,
    /// and close. Idempotent.
    private func requestClose() async {
        guard !closed, !closeRequested else { return }
        closeRequested = true
        streamTask?.cancel()
        await streamTask?.value
        if let receipt = try? await closeReceipt() {
            await sendCloseReady(receipt)
        }
        await close(code: CloseCode.normal, reason: "payment session closed")
    }

    private func sendCloseReady(_ receipt: Receipt) async {
        guard !closeReadySent, !closed else { return }
        closeReadySent = true
        await emit(.closeReady(receipt))
    }

    private func emit(_ frame: SessionWebSocketFrame) async {
        guard !closed else { return }
        guard let text = try? frame.encoded() else { return }
        try? await writer.send(text)
    }

    private func close(code: UInt16, reason: String) async {
        guard !closed else { return }
        closed = true
        streamTask?.cancel()
        await writer.close(code: code, reason: reason)
    }
}
