import Foundation
import MPPCore

/// One event in a metered Tempo session stream, in the Server-Sent Events form the
/// reference SDKs use over `text/event-stream`.
///
/// Three event types flow as the server meters a stream against a payment channel:
/// - ``message``: a chunk of application data.
/// - ``needVoucher``: the channel balance is exhausted mid-stream; the client must
///   POST a higher cumulative voucher before the next chunk is sent.
/// - ``receipt``: the terminal receipt, after the stream completes.
///
/// The wire form of each is `event: <type>\ndata: <payload>\n\n`. A ``message``
/// payload that contains newlines is emitted as one `data:` line per line (the SSE
/// convention, rejoined with newlines on parse); ``needVoucher`` and ``receipt``
/// carry a single JSON `data:` line.
public enum SessionStreamEvent: Sendable, Hashable {
    /// A chunk of streamed application data.
    case message(String)
    /// The channel balance is short for the next chunk; a higher voucher is needed.
    case needVoucher(NeedVoucher)
    /// The terminal session receipt.
    case receipt(Receipt)

    /// The `payment-need-voucher` payload: what the client must authorize to continue.
    public struct NeedVoucher: Sendable, Hashable, Codable {
        /// The `0x`-prefixed channel id.
        public var channelId: String
        /// The cumulative voucher amount needed before the next chunk (decimal).
        public var requiredCumulative: String
        /// The highest cumulative voucher accepted so far (decimal).
        public var acceptedCumulative: String
        /// The on-chain deposit ceiling the channel cannot exceed (decimal).
        public var deposit: String

        public init(
            channelId: String,
            requiredCumulative: String,
            acceptedCumulative: String,
            deposit: String
        ) {
            self.channelId = channelId
            self.requiredCumulative = requiredCumulative
            self.acceptedCumulative = acceptedCumulative
            self.deposit = deposit
        }
    }

    /// The SSE event-type name on the wire.
    private var eventName: String {
        switch self {
        case .message: "message"
        case .needVoucher: "payment-need-voucher"
        case .receipt: "payment-receipt"
        }
    }

    /// The SSE block for this event: `event: <type>` then one or more `data:` lines,
    /// terminated by a blank line.
    ///
    /// - Throws: ``EncodingError`` if the JSON payload of a ``needVoucher`` or
    ///   ``receipt`` cannot be encoded (not expected for these value types).
    public func sseEncoded() throws -> String {
        let dataLines: [String] = switch self {
        case let .message(text):
            // One data: line per line, split on \n (matching the reference SDK's
            // `formatMessageEvent`, which is \n-only); empty lines are preserved.
            text.components(separatedBy: "\n")
        case let .needVoucher(payload):
            try [CanonicalJSON.string(payload)]
        case let .receipt(receipt):
            try [CanonicalJSON.string(receipt)]
        }
        var block = "event: \(eventName)\n"
        for line in dataLines {
            block += "data: \(line)\n"
        }
        block += "\n"
        return block
    }

    /// Parses one SSE block (the text between blank-line boundaries) into an event,
    /// or `nil` if the event type is unknown or its JSON payload is malformed.
    public static func parse(_ block: String) -> SessionStreamEvent? {
        var eventName: String?
        var dataLines: [String] = []
        // Split on \n only, matching the reference SDK's `parseEvent` (mppx is \n-only); the
        // SSE the server emits and the peer emits are both \n-delimited.
        for rawLine in block.components(separatedBy: "\n") {
            if let value = field(rawLine, "event:") {
                eventName = value
            } else if let value = field(rawLine, "data:") {
                dataLines.append(value)
            }
        }
        let payload = dataLines.joined(separator: "\n")
        switch eventName {
        case "message":
            return .message(payload)
        case "payment-need-voucher":
            return decode(NeedVoucher.self, payload).map(SessionStreamEvent.needVoucher)
        case "payment-receipt":
            return decode(Receipt.self, payload).map(SessionStreamEvent.receipt)
        default:
            return nil
        }
    }

    /// The value of an SSE field line (`name:` optionally followed by one space), or
    /// `nil` if the line is not that field.
    private static func field(_ line: String, _ name: String) -> String? {
        guard line.hasPrefix(name) else { return nil }
        var value = Substring(line.dropFirst(name.count))
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ payload: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(payload.utf8))
    }
}
