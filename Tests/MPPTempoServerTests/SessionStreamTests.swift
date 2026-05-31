import Foundation
import MPPCore
import MPPEVM
import MPPTempo
import MPPTempoServer
import Testing

@Suite("SessionStream (SSE metered streaming)")
struct SessionStreamTests {
    private static let channelID = Data(repeating: 0xAB, count: 32)
    private static let addressHex = "0x1111111111111111111111111111111111111111"
    private static let tick = ChannelAmount(10)
    private static let now = Date(timeIntervalSince1970: 1_767_312_000)

    private func address() throws -> EthereumAddress {
        try #require(EthereumAddress(hex: Self.addressHex))
    }

    private func tempo() throws -> MethodName {
        try MethodName("tempo")
    }

    /// Seeds a channel with `highest` authorized and `deposit` on-chain, `spent` 0.
    private func seed(
        _ store: InMemoryChannelStore, highest: ChannelAmount, deposit: ChannelAmount
    ) async throws {
        let state = try ChannelState(
            channelID: Self.channelID, chainID: 1, escrowContract: address(),
            payer: address(), payee: address(), token: address(), authorizedSigner: address(),
            deposit: deposit, highestVoucherAmount: highest
        )
        try await store.update(Self.channelID) { _ in state }
    }

    private func collect(
        _ stream: AsyncThrowingStream<SessionStreamEvent, any Error>
    ) async throws -> [SessionStreamEvent] {
        var events: [SessionStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func serve(
        store: InMemoryChannelStore,
        chunks: [String],
        prepaidUnits: Int = 0,
        maxVoucherWaitPolls: Int = 600,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) throws -> AsyncThrowingStream<SessionStreamEvent, any Error> {
        let source = ChunkSource(chunks)
        let target = try SessionStream.Target(
            channelID: Self.channelID, method: tempo(), challengeID: "ch-1", tickCost: Self.tick
        )
        let options = SessionStream.Options(
            prepaidUnits: prepaidUnits, pollInterval: .milliseconds(1),
            maxVoucherWaitPolls: maxVoucherWaitPolls, now: { Self.now }, sleep: sleep
        )
        return SessionStream.serve(
            store: store, target: target, options: options, next: { await source.next() }
        )
    }

    // MARK: codec

    @Test("each event type round-trips through the SSE wire form")
    func codecRoundTrip() throws {
        let message = SessionStreamEvent.message("line one\nline two")
        let need = SessionStreamEvent.needVoucher(.init(
            channelId: "0xabcd", requiredCumulative: "30", acceptedCumulative: "20", deposit: "1000"
        ))
        let receipt = try SessionStreamEvent.receipt(Receipt(
            method: tempo(), timestamp: RFC3339DateTime(date: Self.now), reference: "0xabcd"
        ))
        for event in [message, need, receipt] {
            let encoded = try event.sseEncoded()
            #expect(encoded.hasSuffix("\n\n")) // SSE blocks end with a blank line
            #expect(SessionStreamEvent.parse(encoded) == event)
        }
    }

    @Test("a multi-line message emits one data line per line")
    func multiLineMessage() throws {
        let encoded = try SessionStreamEvent.message("a\nb\nc").sseEncoded()
        #expect(encoded == "event: message\ndata: a\ndata: b\ndata: c\n\n")
    }

    @Test("an unknown event type parses to nil")
    func unknownEvent() {
        #expect(SessionStreamEvent.parse("event: other\ndata: x\n\n") == nil)
    }

    // MARK: metering

    @Test("a fully funded stream charges every chunk and ends with a receipt")
    func fundedStream() async throws {
        let store = InMemoryChannelStore()
        try await seed(store, highest: ChannelAmount(100), deposit: ChannelAmount(1000))
        let events = try await collect(serve(store: store, chunks: ["a", "b", "c"]))

        #expect(events.count == 4)
        #expect(events.prefix(3) == [.message("a"), .message("b"), .message("c")])
        guard case .receipt = events[3] else { Issue.record("last event is the receipt"); return }
        let channel = try #require(await store.channel(Self.channelID))
        #expect(channel.spent == ChannelAmount(30))
        #expect(channel.units == 3)
    }

    @Test("prepaid units skip the leading charges")
    func prepaidSkipsCharge() async throws {
        let store = InMemoryChannelStore()
        // Only enough headroom for one chunk; the first is prepaid, so two flow.
        try await seed(store, highest: Self.tick, deposit: ChannelAmount(1000))
        let events = try await collect(serve(store: store, chunks: ["a", "b"], prepaidUnits: 1))
        #expect(events.prefix(2) == [.message("a"), .message("b")])
        let channel = try #require(await store.channel(Self.channelID))
        #expect(channel.spent == Self.tick) // only the second chunk charged
        #expect(channel.units == 1)
    }

    @Test("an exhausted balance emits need-voucher and resumes once a voucher raises it")
    func needVoucherThenResume() async throws {
        let store = InMemoryChannelStore()
        try await seed(store, highest: Self.tick, deposit: ChannelAmount(1000)) // funds one chunk

        // The injected wait simulates the client's voucher POST arriving: it raises the
        // channel's highest cumulative, so the next poll has headroom.
        let raised = Raised()
        let sleep: @Sendable (Duration) async throws -> Void = { _ in
            if await raised.firstCall() {
                try await store.update(Self.channelID) { current in
                    guard var channel = current else { return current }
                    channel.highestVoucherAmount = ChannelAmount(20)
                    return channel
                }
            }
        }
        let events = try await collect(serve(store: store, chunks: ["a", "b"], sleep: sleep))

        #expect(events.count == 4)
        #expect(events[0] == .message("a"))
        guard case let .needVoucher(need) = events[1] else {
            Issue.record("second event is need-voucher"); return
        }
        #expect(need.requiredCumulative == "20") // spent(10) + tick(10)
        #expect(need.acceptedCumulative == "10")
        #expect(events[2] == .message("b"))
        guard case .receipt = events[3] else { Issue.record("last event is the receipt"); return }
        #expect(try await #require(store.channel(Self.channelID)).spent == ChannelAmount(20))
    }

    @Test("a closed channel ends the stream with channelClosed")
    func closedChannelEndsStream() async throws {
        let store = InMemoryChannelStore()
        try await seed(store, highest: Self.tick, deposit: ChannelAmount(1000))
        try await store.update(Self.channelID) { current in
            guard var channel = current else { return current }
            channel.closing = true
            return channel
        }
        await #expect(throws: SessionStream.StreamError.channelClosed(reason: "closing")) {
            _ = try await collect(serve(store: store, chunks: ["a"]))
        }
    }

    @Test("an unanswered need-voucher times out")
    func voucherTimeout() async throws {
        let store = InMemoryChannelStore()
        try await seed(store, highest: ChannelAmount.zero, deposit: ChannelAmount(1000))
        await #expect(throws: SessionStream.StreamError.voucherTimeout) {
            _ = try await collect(serve(store: store, chunks: ["a"], maxVoucherWaitPolls: 3))
        }
    }
}

// MARK: test support

/// A Sendable pull source over a fixed list of chunks.
private actor ChunkSource {
    private var remaining: [String]
    init(_ chunks: [String]) {
        remaining = chunks
    }

    func next() -> String? {
        remaining.isEmpty ? nil : remaining.removeFirst()
    }
}

/// Tracks whether a closure has been called before (one-shot latch).
private actor Raised {
    private var called = false
    func firstCall() -> Bool {
        defer { called = true }
        return !called
    }
}
