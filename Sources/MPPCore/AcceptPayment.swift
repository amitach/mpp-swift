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
    ///
    /// - Throws: ``ValidationError/qualityOutOfRange(_:)`` if `quality` is not a
    ///   finite value in `0...1`, so a range can never format to an invalid `q`.
    public init(
        method: Wildcard<MethodName>,
        intent: Wildcard<IntentName>,
        quality: Double = 1
    ) throws(ValidationError) {
        guard quality.isFinite, (0 ... 1).contains(quality) else {
            throw .qualityOutOfRange(quality)
        }
        self.method = method
        self.intent = intent
        self.quality = quality
    }

    /// Whether this range covers the given concrete method and intent
    /// (wildcards match anything). Does not consider the quality weight.
    public func matches(method: MethodName, intent: IntentName) -> Bool {
        self.method.matches(method) && self.intent.matches(intent)
    }

    /// A reason a ``PaymentRange`` could not be constructed.
    public enum ValidationError: Error, Sendable, Hashable {
        /// The quality weight was not a finite value in `0...1`.
        case qualityOutOfRange(Double)
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
        // A grammar-valid qvalue is always in 0...1, so this init never throws on
        // the parse path; map defensively to keep the typed throws coherent.
        do {
            return try PaymentRange(method: method, intent: intent, quality: quality)
        } catch {
            throw .invalidQuality(String(quality))
        }
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
        // The ABNF allows at most one weight and no other parameter, so anything
        // past a single `q=` segment is malformed (no last-wins, no extras).
        guard params.count == 1 else { throw .malformedToken(params.joined(separator: ";")) }
        let param = first.trimmingCharacters(in: .whitespaces)
        guard param.lowercased().hasPrefix("q=") else { throw .malformedToken(param) }
        let raw = String(param.dropFirst(2))
        guard isQValue(raw) else { throw .invalidQuality(raw) }
        // A grammar-valid qvalue is in 0...1 by construction, so the range is not
        // re-checked here. Normalize a bare trailing dot ("0." / "1.") so `Double`
        // can parse it.
        let numeric = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
        guard let value = Double(numeric) else { throw .invalidQuality(raw) }
        return value
    }

    /// Whether `raw` is an RFC 9110 §12.4.2 `qvalue`:
    /// `( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] )`. Stricter than
    /// `Double`, which would admit hex, scientific, signed, and >3-decimal forms;
    /// a bare trailing dot ("0." / "1.") is allowed, as the ABNF's `0*3` permits
    /// zero fractional digits.
    private static func isQValue(_ raw: String) -> Bool {
        guard let lead = raw.first, lead == "0" || lead == "1" else { return false }
        let rest = raw.dropFirst()
        if rest.isEmpty { return true } // "0" or "1"
        guard rest.first == "." else { return false } // a fractional part must follow
        let fraction = rest.dropFirst()
        guard fraction.count <= 3 else { return false } // 0*3 (empty allowed: "0." / "1.")
        return lead == "0"
            ? fraction.unicodeScalars.allSatisfy { (0x30 ... 0x39).contains($0.value) }
            : fraction.allSatisfy { $0 == "0" }
    }

    private static func token(_ wildcard: Wildcard<some RawStringValidated>) -> String {
        switch wildcard {
        case .any: "*"
        case let .value(value): value.rawValue
        }
    }

    private static func formatQuality(_ quality: Double) -> String {
        // The wire qvalue (RFC 9110 §12.4.2) is 0...1 with at most three decimals,
        // so round to that precision (%.3f, C locale, no scientific notation) and
        // strip trailing zeros: 0.5 -> "0.5", 1 -> "1", 0.1234 -> "0.123".
        var rendered = String(format: "%.3f", quality)
        if rendered.contains(".") {
            while rendered.hasSuffix("0") {
                rendered.removeLast()
            }
            if rendered.hasSuffix(".") { rendered.removeLast() }
        }
        return rendered
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
