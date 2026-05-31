import Foundation
import MPPCore
import MPPTempo

/// Meters a stream of application chunks against a Tempo payment channel,
/// pay-as-you-go, emitting Server-Sent ``SessionStreamEvent``s.
///
/// Each chunk costs ``Target/tickCost`` drawn from the channel's available balance
/// (`highestVoucherAmount - spent`). When the balance is short, the stream emits a
/// ``SessionStreamEvent/needVoucher(_:)`` and waits: the client POSTs a higher
/// cumulative voucher to the session endpoint (verified by ``SessionMethod``, which
/// advances the channel's `highestVoucherAmount`), and this loop, polling the store,
/// resumes once the headroom exists. When the chunk source is exhausted it emits the
/// terminal ``SessionStreamEvent/receipt(_:)``.
///
/// The draw is the channel store's atomic `deductFromChannel`, so metering is
/// race-free against concurrent vouchers/closes. The clock and the poll sleep are
/// injected (``Options``, defaulting to the system clock and `Task.sleep`) so tests
/// are deterministic. ``Options/prepaidUnits`` skips the first N charges: an SSE
/// request that arrived on the same credential as a channel `open`/`voucher` was
/// already charged once by ``SessionMethod``, so the first chunk is not
/// double-charged.
public enum SessionStream {
    /// What is being metered: the channel, its receipt identity, and the per-chunk cost.
    public struct Target: Sendable {
        /// The channel being metered.
        public var channelID: Data
        /// The receipt method name (`tempo`).
        public var method: MethodName
        /// The session challenge id, echoed into the receipt.
        public var challengeID: String
        /// The per-chunk charge.
        public var tickCost: ChannelAmount

        public init(
            channelID: Data, method: MethodName, challengeID: String, tickCost: ChannelAmount
        ) {
            self.channelID = channelID
            self.method = method
            self.challengeID = challengeID
            self.tickCost = tickCost
        }
    }

    /// Tuning and injected dependencies for a metered stream.
    public struct Options: Sendable {
        /// Charges to skip up front (the HTTP request that opened the stream already
        /// paid for them).
        public var prepaidUnits: Int
        /// How long to wait between balance re-checks while a voucher is outstanding.
        public var pollInterval: Duration
        /// How many polls to wait for a voucher before giving up with
        /// ``StreamError/voucherTimeout``.
        public var maxVoucherWaitPolls: Int
        /// The clock for the receipt timestamp.
        public var now: @Sendable () -> Date
        /// The wait primitive (injected for tests).
        public var sleep: @Sendable (Duration) async throws -> Void

        public init(
            prepaidUnits: Int = 0,
            pollInterval: Duration = .milliseconds(100),
            maxVoucherWaitPolls: Int = 600,
            now: @escaping @Sendable () -> Date = { Date() },
            sleep: @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            }
        ) {
            self.prepaidUnits = prepaidUnits
            self.pollInterval = pollInterval
            self.maxVoucherWaitPolls = maxVoucherWaitPolls
            self.now = now
            self.sleep = sleep
        }
    }

    /// A reason a metered stream ended early.
    public enum StreamError: Error, Sendable, Hashable {
        /// The channel disappeared from the store mid-stream.
        case channelNotFound
        /// The channel was finalized or closing; no further chunk may be charged.
        case channelClosed(reason: String)
        /// The client did not raise the voucher within the wait budget.
        case voucherTimeout
    }

    /// Serves a metered SSE stream pulling chunks from `next` until it returns `nil`.
    ///
    /// - Returns: a stream of ``SessionStreamEvent``s; it finishes by throwing on a
    ///   closed/missing channel or a voucher timeout.
    public static func serve(
        store: any ChannelStore,
        target: Target,
        options: Options = .init(),
        next: @escaping @Sendable () async throws -> String?
    ) -> AsyncThrowingStream<SessionStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var prepaid = max(0, options.prepaidUnits)
                    while let chunk = try await next() {
                        if prepaid > 0 {
                            prepaid -= 1
                        } else {
                            try await meterOneTick(
                                store: store, target: target, options: options,
                                emit: { continuation.yield($0) }
                            )
                        }
                        continuation.yield(.message(chunk))
                    }
                    if let channel = await store.channel(target.channelID) {
                        continuation.yield(.receipt(SessionReceipt.make(
                            method: target.method, now: options.now(),
                            challengeID: target.challengeID, channel: channel
                        )))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Draws one ``Target/tickCost`` from the channel, emitting a single
    /// ``SessionStreamEvent/needVoucher(_:)`` and polling until the balance allows it.
    private static func meterOneTick(
        store: any ChannelStore,
        target: Target,
        options: Options,
        emit: @Sendable (SessionStreamEvent) -> Void
    ) async throws {
        var emittedNeed = false
        var polls = 0
        while true {
            do {
                try await deductFromChannel(
                    store, channelID: target.channelID, amount: target.tickCost
                )
                return
            } catch let error as ChannelError {
                switch error {
                case .insufficientBalance:
                    if !emittedNeed {
                        try await emit(.needVoucher(needVoucher(store, target)))
                        emittedNeed = true
                    }
                    polls += 1
                    guard polls <= options.maxVoucherWaitPolls else {
                        throw StreamError.voucherTimeout
                    }
                    try await options.sleep(options.pollInterval)
                case let .closed(reason):
                    throw StreamError.channelClosed(reason: reason)
                case .notFound:
                    throw StreamError.channelNotFound
                }
            }
        }
    }

    /// The need-voucher payload for the current channel snapshot: the cumulative the
    /// client must reach (`spent + tickCost`) to draw the next chunk.
    private static func needVoucher(
        _ store: any ChannelStore, _ target: Target
    ) async throws -> SessionStreamEvent.NeedVoucher {
        guard let channel = await store.channel(target.channelID)
        else { throw StreamError.channelNotFound }
        let required = channel.spent.adding(target.tickCost) ?? channel.spent
        return SessionStreamEvent.NeedVoucher(
            channelId: SessionReceipt.channelHex(target.channelID),
            requiredCumulative: required.decimalString,
            acceptedCumulative: channel.highestVoucherAmount.decimalString,
            deposit: channel.deposit.decimalString
        )
    }
}
