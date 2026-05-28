/// A payment challenge: the parsed `WWW-Authenticate: Payment` parameters a
/// server returns with a `402 Payment Required` response.
///
/// Per `draft-httpauth-payment-00` §5.1, the challenge carries five required
/// parameters (`id`, `realm`, `method`, `intent`, `request`) and four optional
/// ones (`digest`, `expires`, `description`, `opaque`). Typed fields enforce the
/// spec grammar at the parse boundary: `method` and `intent` are validated, and
/// `request` / `opaque` keep their base64url-encoded form verbatim so the
/// challenge-id HMAC binding sees exactly the bytes the server sent.
public struct Challenge: Sendable, Hashable, Codable {
    /// Unique challenge identifier the server binds to the other parameters.
    public let id: String
    /// Protection-space identifier (RFC 9110 `realm`).
    public let realm: String
    /// Payment method identifier (lowercase ASCII).
    public let method: MethodName
    /// Payment intent (a registered intent token).
    public let intent: IntentName
    /// Method-specific request data, base64url(JCS(json)). Preserved verbatim;
    /// a malformed encoding surfaces when read via ``EncodedJSON/decodedData()``,
    /// not at parse time, so the challenge-id binding always sees the literal bytes.
    public let request: EncodedJSON
    /// Content digest of the request body (RFC 9530), preserved verbatim.
    public let digest: String?
    /// When the challenge expires, if the server set a deadline.
    public let expires: Expires?
    /// Human-readable description, for display only.
    ///
    /// Named for the spec's `description` parameter. `Challenge` deliberately
    /// does not conform to `CustomStringConvertible`, so this optional field
    /// does not collide with that protocol's non-optional `description`.
    public let description: String?
    /// Server-defined correlation data, base64url(JCS(json)).
    public let opaque: EncodedJSON?

    /// Creates a challenge from its parameters (for minting on the server side).
    public init(
        id: String,
        realm: String,
        method: MethodName,
        intent: IntentName,
        request: EncodedJSON,
        digest: String? = nil,
        expires: Expires? = nil,
        description: String? = nil,
        opaque: EncodedJSON? = nil
    ) {
        self.id = id
        self.realm = realm
        self.method = method
        self.intent = intent
        self.request = request
        self.digest = digest
        self.expires = expires
        self.description = description
        self.opaque = opaque
    }

    /// Parses a challenge from a `WWW-Authenticate` header value.
    ///
    /// - Parameter headerValue: The full header value, which may contain other
    ///   authentication schemes alongside `Payment`.
    /// - Throws: ``ParsingError``.
    ///
    /// `method` and `intent` are validated against their grammars here. All
    /// other values (including `id` and `realm`) are accepted verbatim: the
    /// challenge-id binding and request decodability are checked by later
    /// layers, not by this parser, so the bound bytes are never altered.
    public init(headerValue: String) throws(ParsingError) {
        let parameters: [String: String]
        do {
            parameters = try PaymentAuthScheme.parseParameters(from: headerValue)
        } catch {
            throw .header(error)
        }

        id = try Self.require(parameters, "id")
        realm = try Self.require(parameters, "realm")

        let methodValue = try Self.require(parameters, "method")
        do {
            method = try MethodName(methodValue)
        } catch {
            throw .invalidMethod(error)
        }

        let intentValue = try Self.require(parameters, "intent")
        do {
            intent = try IntentName(intentValue)
        } catch {
            throw .invalidIntent(error)
        }

        request = try EncodedJSON(Self.require(parameters, "request"))

        digest = parameters["digest"]
        description = parameters["description"]
        opaque = parameters["opaque"].map(EncodedJSON.init)

        if let expiresValue = parameters["expires"] {
            do {
                expires = try Expires(expiresValue)
            } catch {
                throw .invalidExpires(error)
            }
        } else {
            expires = nil
        }
    }

    /// The `WWW-Authenticate: Payment` header value for this challenge.
    ///
    /// Parameters are emitted in spec order, omitting absent optionals. Round-
    /// trips with ``init(headerValue:)`` for any challenge this type produced.
    public var headerValue: String {
        var parameters: [(key: String, value: String)] = [
            ("id", id),
            ("realm", realm),
            ("method", method.rawValue),
            ("intent", intent.rawValue),
            ("request", request.rawValue),
        ]
        if let digest { parameters.append(("digest", digest)) }
        if let expires { parameters.append(("expires", expires.rawValue)) }
        if let description { parameters.append(("description", description)) }
        if let opaque { parameters.append(("opaque", opaque.rawValue)) }
        return PaymentAuthScheme.formatParameters(parameters)
    }

    private static func require(
        _ parameters: [String: String], _ name: String
    ) throws(ParsingError) -> String {
        guard let value = parameters[name] else { throw .missingParameter(name) }
        // A present-but-empty required value does not satisfy the requirement and
        // would bind an empty slot in the challenge-id HMAC; reject it here.
        guard !value.isEmpty else { throw .emptyParameter(name) }
        return value
    }

    /// A reason a `WWW-Authenticate` value is not a valid challenge.
    public enum ParsingError: Error, Sendable, Hashable {
        /// The `Payment` scheme or its parameters could not be parsed.
        case header(PaymentAuthScheme.ParseError)
        /// A required parameter was absent.
        case missingParameter(String)
        /// A required parameter was present but had an empty value.
        case emptyParameter(String)
        /// The `method` value is not a valid ``MethodName``.
        case invalidMethod(MethodName.ValidationError)
        /// The `intent` value is not a valid ``IntentName``.
        case invalidIntent(IntentName.ValidationError)
        /// The `expires` value is not a valid RFC 3339 timestamp.
        case invalidExpires(Expires.ParsingError)
    }
}
