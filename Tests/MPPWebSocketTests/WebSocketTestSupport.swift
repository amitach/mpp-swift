import Foundation
import MPPCore
import MPPTempoServer
@testable import MPPWebSocket

/// An in-process WebSocket stand-in shared by the server and client suites. The peer
/// pushes frames in via ``peerSend`` (they arrive on ``inbound``, what the code under test
/// reads); the code under test's outbound frames land in ``sent``; and `close` finishes
/// `inbound` (as a real transport does) so a server `serve` loop returns.
final class InProcessSocket: SessionSocketWriter, @unchecked Sendable {
    let inbound: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var sentFrames: [String] = []
    private var closeCodeValue: UInt16?

    init() {
        var captured: AsyncStream<String>.Continuation!
        inbound = AsyncStream { captured = $0 }
        continuation = captured
    }

    /// A frame from the peer to the code under test (server -> client, or client -> server).
    func peerSend(_ text: String) {
        continuation.yield(text)
    }

    /// End the inbound stream as if the peer hung up without a close handshake.
    func peerFinish() {
        continuation.finish()
    }

    func send(_ text: String) async throws {
        lock.withLock { sentFrames.append(text) }
    }

    func close(code: UInt16, reason _: String) async {
        lock.withLock { if closeCodeValue == nil { closeCodeValue = code } }
        continuation.finish()
    }

    /// The frames the code under test wrote, parsed back from the wire.
    var sent: [SessionWebSocketFrame] {
        lock.withLock { sentFrames.compactMap(SessionWebSocketFrame.parse) }
    }

    var closeCode: UInt16? {
        lock.withLock { closeCodeValue }
    }
}

/// A thread-safe boolean for asserting from inside a `@Sendable` closure.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() {
        lock.withLock { raised = true }
    }

    var isRaised: Bool {
        lock.withLock { raised }
    }
}

/// A thread-safe accumulator for collecting values from inside a `@Sendable` closure.
final class Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    func append(_ value: Value) {
        lock.withLock { items.append(value) }
    }

    var values: [Value] {
        lock.withLock { items }
    }
}

func makeReceipt(_ reference: String) -> Receipt {
    // Force-try in a test: the literals are valid, and a throw would fail the test loudly.
    // swiftlint:disable:next force_try
    try! Receipt(
        method: MethodName("tempo"),
        timestamp: RFC3339DateTime("2026-01-02T00:00:00Z"),
        reference: reference
    )
}

let sampleNeedVoucher = SessionStreamEvent.NeedVoucher(
    channelId: "0xabc", requiredCumulative: "10", acceptedCumulative: "5", deposit: "100"
)
