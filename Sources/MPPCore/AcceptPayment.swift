import Foundation

/// A value or the `*` wildcard.
///
/// The `Accept-Payment` header's tokens are `payment-method-id / "*"` and
/// `intent-token / "*"` (`draft-httpauth-payment-00` §6). This models that
/// "a specific value, or any" choice explicitly so a wildcard can never be
/// misread as an absent value.
public enum Wildcard<Value: Hashable & Sendable>: Sendable, Hashable {
    /// The `*` wildcard: matches any value.
    case any
    /// A specific value: matches only itself.
    case value(Value)

    /// Whether this token matches `candidate`. `any` matches everything.
    public func matches(_ candidate: Value) -> Bool {
        switch self {
        case .any: true
        case let .value(value): value == candidate
        }
    }
}

/// One entry in an `Accept-Payment` header: a (method, intent) the client can
/// pay with, each possibly a wildcard, with a quality weight.
///
/// Per `draft-httpauth-payment-00` §6, a client sends these to declare its
/// supported method/intent combinations. The weight `q` defaults to 1 when
/// omitted; `q=0` means "do not use". This type carries `q` verbatim; the
/// negotiation policy (filter `q>0`, order by descending `q`, prefer the most
/// specific match over a server's challenge set) belongs to the server layer.
public struct PaymentRange: Sendable, Hashable {
    /// The payment method, or `.any` for `*`.
    public let method: Wildcard<MethodName>
    /// The payment intent, or `.any` for `*`.
    public let intent: Wildcard<IntentName>
    /// The quality weight `q`, in `0...1`. Defaults to 1; `0` means "do not use".
    public let quality: Double

    /// Creates a payment range.
    public init(
        method: Wildcard<MethodName>,
        intent: Wildcard<IntentName>,
        quality: Double = 1
    ) {
        self.method = method
        self.intent = intent
        self.quality = quality
    }

    /// Whether this range covers the given concrete method and intent
    /// (wildcards match anything). Does not consider the quality weight.
    public func matches(method: MethodName, intent: IntentName) -> Bool {
        self.method.matches(method) && self.intent.matches(intent)
    }
}

/// Parser and formatter for the `Accept-Payment` request header.
///
/// `Accept-Payment = #payment-range` (`draft-httpauth-payment-00` §6): a
/// comma-separated list of `method-or-* "/" intent-or-*` tokens, each with an
/// optional `;q=` weight. An absent header means "accept any"; that is the
/// caller's interpretation of an empty list, not represented here.
public enum AcceptPayment {
    /// Parses an `Accept-Payment` header value into its ranges.
    ///
    /// Empty list elements (per the RFC 9110 `#` rule) are skipped. Order is
    /// preserved.
    ///
    /// - Throws: ``ParseError``.
    public static func parse(_ headerValue: String) throws(ParseError) -> [PaymentRange] {
        var ranges: [PaymentRange] = []
        for element in headerValue.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = element.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            try ranges.append(parseRange(piece))
        }
        return ranges
    }

    /// Formats ranges as an `Accept-Payment` header value. Emits `;q=` only when
    /// the weight is not the default of 1.
    public static func format(_ ranges: [PaymentRange]) -> String {
        ranges.map { range in
            let token = "\(token(range.method))/\(token(range.intent))"
            return range.quality == 1 ? token : "\(token);q=\(formatQuality(range.quality))"
        }.joined(separator: ", ")
    }

    private static func parseRange(_ piece: String) throws(ParseError) -> PaymentRange {
        let parts = piece.split(separator: ";", omittingEmptySubsequences: false)
        let token = parts[0].trimmingCharacters(in: .whitespaces)

        let slash = token.split(separator: "/", omittingEmptySubsequences: false)
        guard slash.count == 2 else { throw .malformedToken(token) }
        let method = try parseMethod(String(slash[0]).trimmingCharacters(in: .whitespaces))
        let intent = try parseIntent(String(slash[1]).trimmingCharacters(in: .whitespaces))

        let quality = try parseQuality(Array(parts.dropFirst()))
        return PaymentRange(method: method, intent: intent, quality: quality)
    }

    private static func parseMethod(_ value: String) throws(ParseError) -> Wildcard<MethodName> {
        if value == "*" { return .any }
        do {
            return try .value(MethodName(value))
        } catch {
            throw .invalidMethod(error)
        }
    }

    private static func parseIntent(_ value: String) throws(ParseError) -> Wildcard<IntentName> {
        if value == "*" { return .any }
        do {
            return try .value(IntentName(value))
        } catch {
            throw .invalidIntent(error)
        }
    }

    private static func parseQuality(_ params: [Substring]) throws(ParseError) -> Double {
        guard let first = params.first else { return 1 }
        let param = first.trimmingCharacters(in: .whitespaces)
        let lower = param.lowercased()
        guard lower.hasPrefix("q=") else { throw .malformedToken(param) }
        let raw = String(param.dropFirst(2))
        guard let value = Double(raw), (0 ... 1).contains(value) else {
            throw .invalidQuality(raw)
        }
        return value
    }

    private static func token(_ wildcard: Wildcard<some RawStringValidated>) -> String {
        switch wildcard {
        case .any: "*"
        case let .value(value): value.rawValue
        }
    }

    private static func formatQuality(_ quality: Double) -> String {
        // `q` is 0...1 with at most three decimals; %g (C locale) drops trailing
        // zeros, so 0.5 -> "0.5", 0 -> "0".
        String(format: "%g", quality)
    }

    /// A reason an `Accept-Payment` value could not be parsed.
    public enum ParseError: Error, Sendable, Hashable {
        /// A range was not `method-or-* "/" intent-or-*` (with an optional `;q=`).
        case malformedToken(String)
        /// The method token was neither `*` nor a valid ``MethodName``.
        case invalidMethod(MethodName.ValidationError)
        /// The intent token was neither `*` nor a valid ``IntentName``.
        case invalidIntent(IntentName.ValidationError)
        /// The `q` weight was not a number in `0...1`.
        case invalidQuality(String)
    }
}
