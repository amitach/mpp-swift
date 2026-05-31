import Foundation
import MPPCore

/// One message in a metered Tempo session over a WebSocket: the in-band JSON frame
/// form the reference SDKs use, the transport sibling of the SSE
/// ``SessionStreamEvent``.
///
/// Where SSE meters a one-way HTTP response and the client POSTs vouchers on a side
/// channel, a WebSocket carries the whole session in-band as `{ "mpp": <type>, ... }`
/// JSON frames in both directions: the client sends ``authorization`` (the
/// `Authorization: Payment` credential) and ``closeRequest``; the server streams
/// ``message`` / ``needVoucher`` / ``receipt`` and answers a close with
/// ``closeReady``, or reports a ``error``. The metering logic is shared:
/// ``SessionStream/serve(store:target:options:next:)`` produces transport-neutral
/// ``SessionStreamEvent``s, and ``init(_:)`` lifts each into its outbound frame.
public enum SessionWebSocketFrame: Sendable, Hashable {
    /// Client -> server: the `Authorization: Payment` credential header value.
    case authorization(String)
    /// Server -> client: a chunk of streamed application data.
    case message(String)
    /// Server -> client: the channel balance is short; a higher voucher is needed.
    case needVoucher(SessionStreamEvent.NeedVoucher)
    /// Server -> client: the terminal session receipt.
    case receipt(Receipt)
    /// Client -> server: a request to close the session.
    case closeRequest
    /// Server -> client: the close was accepted; carries the settlement receipt.
    case closeReady(Receipt)
    /// Server -> client: the session failed, with an HTTP-style status and message.
    case error(status: Int, message: String)

    /// Lifts a transport-neutral metered-stream event into its outbound WebSocket frame.
    public init(_ event: SessionStreamEvent) {
        switch event {
        case let .message(text): self = .message(text)
        case let .needVoucher(payload): self = .needVoucher(payload)
        case let .receipt(receipt): self = .receipt(receipt)
        }
    }

    /// The `mpp` discriminator on the wire.
    private var tag: String {
        switch self {
        case .authorization: "authorization"
        case .message: "message"
        case .needVoucher: "payment-need-voucher"
        case .receipt: "payment-receipt"
        case .closeRequest: "payment-close-request"
        case .closeReady: "payment-close-ready"
        case .error: "payment-error"
        }
    }

    /// The JSON frame for this message.
    ///
    /// - Throws: ``EncodingError`` if the payload cannot be encoded (not expected for
    ///   these value types).
    public func encoded() throws -> String {
        switch self {
        case let .authorization(value):
            try CanonicalJSON.string(Authorization(mpp: tag, authorization: value))
        case let .message(text):
            try CanonicalJSON.string(Tagged(mpp: tag, data: text))
        case let .needVoucher(payload):
            try CanonicalJSON.string(Tagged(mpp: tag, data: payload))
        case let .receipt(receipt), let .closeReady(receipt):
            try CanonicalJSON.string(Tagged(mpp: tag, data: receipt))
        case .closeRequest:
            try CanonicalJSON.string(Untagged(mpp: tag))
        case let .error(status, message):
            try CanonicalJSON.string(Failure(mpp: tag, status: status, message: message))
        }
    }

    /// Parses a JSON frame, or `nil` if the discriminator is unknown or the payload
    /// is malformed for its type.
    public static func parse(_ json: String) -> SessionWebSocketFrame? {
        let data = Data(json.utf8)
        guard let tag = try? JSONDecoder().decode(Untagged.self, from: data).mpp else { return nil }
        switch tag {
        case "authorization":
            return decode(Authorization.self, data).map { .authorization($0.authorization) }
        case "message":
            return decode(Tagged<String>.self, data).map { .message($0.data) }
        case "payment-need-voucher":
            return decode(Tagged<SessionStreamEvent.NeedVoucher>.self, data)
                .map { .needVoucher($0.data) }
        case "payment-receipt":
            return decode(Tagged<Receipt>.self, data).map { .receipt($0.data) }
        case "payment-close-request":
            return .closeRequest
        case "payment-close-ready":
            return decode(Tagged<Receipt>.self, data).map { .closeReady($0.data) }
        case "payment-error":
            return decode(Failure.self, data).map { .error(status: $0.status, message: $0.message) }
        default:
            return nil
        }
    }

    // MARK: - wire structs

    private struct Untagged: Codable { let mpp: String }
    private struct Tagged<Payload: Codable & Sendable>: Codable {
        let mpp: String; let data: Payload
    }

    private struct Authorization: Codable { let mpp: String; let authorization: String }
    private struct Failure: Codable { let mpp: String; let status: Int; let message: String }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
