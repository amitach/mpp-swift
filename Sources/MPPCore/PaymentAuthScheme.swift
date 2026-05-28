/// Parser and formatter for the parameters of the `Payment` HTTP authentication
/// scheme, shared by the challenge (`WWW-Authenticate`), credential
/// (`Authorization`), and receipt headers.
///
/// Per `draft-httpauth-payment-00` §5.1 (and the RFC 9110 `auth-param`
/// grammar), a header value carries one or more comma-separated `key=value`
/// auth-params following the `Payment` scheme token. Keys are
/// `[A-Za-z0-9_-]+`; values are either bare tokens or quoted-strings with
/// backslash escapes. The header MAY contain other authentication schemes
/// alongside `Payment`.
///
/// Per the spec: the `Payment` scheme is extracted case-insensitively even when
/// other schemes are present; **duplicate parameters are rejected**; and values
/// are preserved **verbatim** so the challenge-id binding sees exactly what was
/// sent. Parameter *names* are case-insensitive
/// per RFC 9110 §11.2, so they are lower-cased on parse (this also makes
/// duplicate detection catch case variants); parameter *values* are untouched.
public enum PaymentAuthScheme {
    /// The authentication scheme name.
    public static let name = "Payment"

    /// Parses the `Payment`-scheme parameters from a header value.
    ///
    /// - Parameter headerValue: A `WWW-Authenticate` / `Authorization` /
    ///   `Payment-Receipt` value, possibly containing other schemes.
    /// - Returns: The parameters, with values preserved verbatim.
    /// - Throws: ``ParseError``.
    public static func parseParameters(
        from headerValue: String
    ) throws(ParseError) -> [String: String] {
        guard let parameters = extractSchemeParameters(headerValue) else {
            throw .missingScheme
        }
        return try parseAuthParameters(parameters)
    }

    /// Formats ordered parameters as a `Payment` header value, quoting and
    /// escaping every value.
    public static func formatParameters(_ parameters: [(key: String, value: String)]) -> String {
        let rendered = parameters.map { "\($0.key)=\"\(escape($0.value))\"" }
        return "\(name) \(rendered.joined(separator: ", "))"
    }

    /// A reason a header value could not be parsed.
    public enum ParseError: Error, Sendable, Hashable {
        /// No `Payment` scheme was present in the header.
        case missingScheme
        /// A parameter was missing its key.
        case malformedParameter
        /// A quoted-string value was opened but never closed.
        case unterminatedQuotedString
        /// The same parameter key appeared more than once.
        case duplicateParameter(String)
    }

    // MARK: - Scheme extraction

    /// Returns the parameter substring following the `Payment` scheme token, or
    /// `nil` if no `Payment` scheme is present. Quote-aware so a `Payment`
    /// substring inside another scheme's quoted value is not mistaken for the
    /// scheme.
    private static func extractSchemeParameters(_ header: String) -> String? {
        let characters = Array(header)
        let scheme = Array(name)
        var inQuotes = false
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuotes = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                inQuotes = true
                index += 1
                continue
            }
            if startsWithSchemeToken(characters, at: index, scheme: scheme),
               prefixAllowsScheme(characters, before: index) {
                var start = index + scheme.count
                while start < characters.count, characters[start].isWhitespace {
                    start += 1
                }
                return String(characters[start...])
            }
            index += 1
        }
        return nil
    }

    /// Whether `Payment` (case-insensitive) starts at `index` and is followed by
    /// whitespace, so `Payments` or a trailing `Payment` does not match.
    private static func startsWithSchemeToken(
        _ characters: [Character], at index: Int, scheme: [Character]
    ) -> Bool {
        let end = index + scheme.count
        guard end < characters.count else { return false }
        guard characters[index ..< end].elementsEqual(scheme, by: {
            $0.lowercased() == $1.lowercased()
        }) else { return false }
        return characters[end].isWhitespace
    }

    /// The text before the scheme must be empty or end with a comma (a scheme
    /// boundary), otherwise the match is inside another token.
    private static func prefixAllowsScheme(_ characters: [Character], before index: Int) -> Bool {
        let prefix = String(characters[0 ..< index]).trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty || prefix.hasSuffix(",")
    }

    // MARK: - Parameter parsing

    private static func parseAuthParameters(
        _ input: String
    ) throws(ParseError) -> [String: String] {
        let characters = Array(input)
        var result: [String: String] = [:]
        var index = 0

        while index < characters.count {
            while index < characters.count,
                  characters[index].isWhitespace || characters[index] == "," {
                index += 1
            }
            if index >= characters.count { break }

            let keyStart = index
            while index < characters.count, isKeyCharacter(characters[index]) {
                index += 1
            }
            // Auth-param names are case-insensitive (RFC 9110 §11.2); lower-case
            // the key so case variants collide for duplicate detection and so
            // downstream lookups (which use lowercase spec names) always match.
            let key = String(characters[keyStart ..< index]).lowercased()
            if key.isEmpty { throw .malformedParameter }

            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            // No '=' after the token: this is the start of another scheme, stop.
            guard index < characters.count, characters[index] == "=" else { break }
            index += 1

            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }

            let value: String
            (value, index) = try readValue(characters, from: index)

            if result[key] != nil { throw .duplicateParameter(key) }
            result[key] = value
        }
        return result
    }

    private static func readValue(
        _ characters: [Character], from start: Int
    ) throws(ParseError) -> (value: String, nextIndex: Int) {
        if start < characters.count, characters[start] == "\"" {
            return try readQuotedValue(characters, from: start + 1)
        }
        var index = start
        while index < characters.count, characters[index] != "," {
            index += 1
        }
        let raw = String(characters[start ..< index]).trimmingCharacters(in: .whitespaces)
        return (raw, index)
    }

    private static func readQuotedValue(
        _ characters: [Character], from start: Int
    ) throws(ParseError) -> (value: String, nextIndex: Int) {
        var index = start
        var value = ""
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return (value, index)
            } else {
                value.append(character)
            }
        }
        throw .unterminatedQuotedString
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
