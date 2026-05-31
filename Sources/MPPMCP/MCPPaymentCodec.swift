import Foundation
import MCP
import MPPCore

/// Translates the MPP `Challenge` / `Credential` / `Receipt` types to and from the native-JSON
/// shapes the MCP transport carries, and builds / parses the `-32042` error `data` frame
/// (`{ httpStatus, challenges, problem? }`), per `draft-payment-transport-mcp-00`.
///
/// The one shape that differs from the types' own `Codable`: over MCP a challenge's `request`
/// (and a credential's echoed challenge) travels as a NATIVE JSON object, whereas `Challenge`
/// stores it as `EncodedJSON` (base64url of the JCS form) and its synthesized `Codable` emits the
/// base64url string. So `Challenge` / `Credential` are mapped field by field with `request`
/// decoded to / re-encoded from native JSON; `Receipt` and `ProblemDetails` are plain structs,
/// so they round-trip through their own `Codable` via a JSON data hop.
enum MCPPaymentCodec {
    /// The MCP-binding receipt carries the challenge id alongside the base receipt fields.
    static let challengeIDKey = "challengeId"

    enum CodecError: Error, Hashable {
        /// An `EncodedJSON` payload could not be decoded, or a native value could not be
        /// re-encoded.
        case malformedRequest
        case missingField(String)
        case invalidField(String)
    }

    // MARK: - Challenge

    static func value(for challenge: Challenge) throws -> Value {
        var object: [String: Value] = try [
            "id": .string(challenge.id),
            "realm": .string(challenge.realm),
            "method": .string(challenge.method.rawValue),
            "intent": .string(challenge.intent.rawValue),
            "request": nativeValue(from: challenge.request),
        ]
        // `digest` is omitted over MCP (no HTTP body); pass it through if a caller set one.
        if let digest = challenge.digest { object["digest"] = .string(digest) }
        if let expires = challenge.expires { object["expires"] = .string(expires.rawValue) }
        if let description = challenge.description { object["description"] = .string(description) }
        // `opaque` is server-correlation data: emit its verbatim wire string so the id binding
        // (which uses `opaque.rawValue`) round-trips byte-for-byte.
        if let opaque = challenge.opaque { object["opaque"] = .string(opaque.rawValue) }
        return .object(object)
    }

    static func challenge(from value: Value) throws -> Challenge {
        guard let object = value.objectValue else { throw CodecError.invalidField("challenge") }
        let id = try requiredString(object, "id")
        let realm = try requiredString(object, "realm")
        let methodRaw = try requiredString(object, "method")
        let intentRaw = try requiredString(object, "intent")
        guard let requestValue = object["request"] else { throw CodecError.missingField("request") }

        let method: MethodName
        do { method = try MethodName(methodRaw) } catch { throw CodecError.invalidField("method") }
        let intent: IntentName
        do { intent = try IntentName(intentRaw) } catch { throw CodecError.invalidField("intent") }

        let expires: Expires?
        if let expiresRaw = object["expires"]?.stringValue {
            do { expires = try Expires(expiresRaw) } catch {
                throw CodecError.invalidField("expires")
            }
        } else {
            expires = nil
        }

        // `opaque` is emitted as its verbatim wire string (it binds into the challenge id). If a
        // peer sends it as a non-string, FAIL CLOSED rather than silently drop it: dropping would
        // change the binding input and surface as an opaque verification failure later.
        let opaque: EncodedJSON?
        if let opaqueValue = object["opaque"] {
            guard let opaqueString = opaqueValue.stringValue else {
                throw CodecError.invalidField("opaque")
            }
            opaque = EncodedJSON(opaqueString)
        } else {
            opaque = nil
        }

        return try Challenge(
            id: id,
            realm: realm,
            method: method,
            intent: intent,
            request: encodedJSON(from: requestValue),
            digest: object["digest"]?.stringValue,
            expires: expires,
            description: object["description"]?.stringValue,
            opaque: opaque
        )
    }

    // MARK: - Credential

    static func value(for credential: Credential) throws -> Value {
        var object: [String: Value] = try [
            "challenge": value(for: credential.challenge),
            "payload": Value(JSONValue.object(credential.payload)),
        ]
        if let source = credential.source { object["source"] = .string(source) }
        return .object(object)
    }

    static func credential(from value: Value) throws -> Credential {
        guard let object = value.objectValue else { throw CodecError.invalidField("credential") }
        guard let challengeValue = object["challenge"]
        else { throw CodecError.missingField("challenge") }
        guard let payloadValue = object["payload"] else { throw CodecError.missingField("payload") }

        let payloadJSON: JSONValue
        do { payloadJSON = try JSONValue(mcp: payloadValue) } catch {
            throw CodecError.invalidField("payload")
        }
        guard case let .object(payload) = payloadJSON
        else { throw CodecError.invalidField("payload") }

        return try Credential(
            challenge: challenge(from: challengeValue),
            source: object["source"]?.stringValue,
            payload: payload
        )
    }

    // MARK: - Receipt (+ the MCP-binding challengeId)

    static func value(for receipt: Receipt, challengeID: String) throws -> Value {
        let encoded = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(Value.self, from: encoded)
        guard case var .object(object) = decoded else { throw CodecError.invalidField("receipt") }
        object[challengeIDKey] = .string(challengeID)
        return .object(object)
    }

    static func receipt(from value: Value) throws -> Receipt {
        let encoded = try JSONEncoder().encode(value)
        do {
            return try JSONDecoder().decode(Receipt.self, from: encoded)
        } catch {
            throw CodecError.invalidField("receipt")
        }
    }

    // MARK: - The -32042 error.data frame

    static func errorData(
        challenge: Challenge,
        problem: ProblemDetails?,
        httpStatus: Int = 402
    ) throws -> [String: Value] {
        var data: [String: Value] = try [
            "httpStatus": .int(httpStatus),
            "challenges": .array([value(for: challenge)]),
        ]
        if let problem {
            let encoded = try JSONEncoder().encode(problem)
            data["problem"] = try JSONDecoder().decode(Value.self, from: encoded)
        }
        return data
    }

    static func challenges(fromErrorData data: [String: Value]) throws -> [Challenge] {
        guard let array = data["challenges"]?.arrayValue
        else { throw CodecError.missingField("challenges") }
        return try array.map { try challenge(from: $0) }
    }

    static func problem(fromErrorData data: [String: Value]) throws -> ProblemDetails? {
        guard let problemValue = data["problem"] else { return nil }
        let encoded = try JSONEncoder().encode(problemValue)
        do {
            return try JSONDecoder().decode(ProblemDetails.self, from: encoded)
        } catch {
            throw CodecError.invalidField("problem")
        }
    }

    // MARK: - EncodedJSON <-> native Value

    /// Decodes an `EncodedJSON` (base64url of JCS) to the native JSON `Value` the MCP wire carries.
    private static func nativeValue(from encoded: EncodedJSON) throws -> Value {
        let data: Data
        do { data = try encoded.decodedData() } catch { throw CodecError.malformedRequest }
        let json: JSONValue
        do { json = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
            throw CodecError.malformedRequest
        }
        return Value(json)
    }

    /// Re-encodes a native JSON `Value` to `EncodedJSON`; the JCS form is recomputed so the
    /// challenge-id binding recomputes identically (JCS parity with the peer is verified).
    private static func encodedJSON(from value: Value) throws -> EncodedJSON {
        let json: JSONValue
        do { json = try JSONValue(mcp: value) } catch { throw CodecError.malformedRequest }
        return EncodedJSON(json: json)
    }

    private static func requiredString(_ object: [String: Value], _ key: String) throws -> String {
        guard let string = object[key]?.stringValue else { throw CodecError.missingField(key) }
        return string
    }
}
