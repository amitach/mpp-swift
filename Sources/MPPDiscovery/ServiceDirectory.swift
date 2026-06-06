import Foundation

/// One service in the MPP ecosystem directory (`mpp.dev/services`): an agent-payable endpoint with
/// its categories. Decoded from the directory's JSON (the `/api/services` endpoint, or the embedded
/// JSON block of `/services/llms.txt`).
///
/// Rail-agnostic: the directory entry says what a service *is* and *where* it is, not how it bills;
/// the rail and price are negotiated by the live `402` at the endpoint (which ``MPPDiscovery`` and
/// the `402` client handle). `serviceURL` is kept as the raw string and exposed as a parsed ``url``
/// so one malformed entry can never fail decoding of the whole directory.
public struct ServiceDirectoryEntry: Sendable, Hashable, Codable {
    /// The stable directory id (for example `anthropic`, `exa`).
    public let id: String
    /// The human-readable name (for example `Anthropic`, `Exa`).
    public let name: String
    /// The service's base URL, verbatim from the directory.
    public let serviceURL: String
    /// A one-line description of what the service does.
    public let description: String
    /// The directory categories (for example `["ai"]`, `["search", "ai"]`), lowercased by the
    /// directory.
    public let categories: [String]

    /// Creates a directory entry. Decoding from the directory's JSON is the usual path; this
    /// initializer lets a consumer build one directly (a fixture, a test, a hand-assembled
    /// directory), matching the explicit `public init` every other ``MPPDiscovery`` model declares.
    public init(
        id: String,
        name: String,
        serviceURL: String,
        description: String,
        categories: [String]
    ) {
        self.id = id
        self.name = name
        self.serviceURL = serviceURL
        self.description = description
        self.categories = categories
    }

    /// ``serviceURL`` parsed, or `nil` if it is not a valid URL.
    public var url: URL? {
        URL(string: serviceURL)
    }

    /// Whether this entry is tagged with `category` (case-insensitive).
    public func isIn(category: String) -> Bool {
        categories.contains { $0.caseInsensitiveCompare(category) == .orderedSame }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, serviceURL = "serviceUrl", description, categories
    }
}

/// Parses the MPP service directory.
///
/// The directory is published two ways, both handled here: as a raw JSON array at
/// `https://mpp.dev/api/services`, and as a ```` ```json ```` block inside the markdown at
/// `https://mpp.dev/services/llms.txt`. The SDK does not fetch (no transport coupling); a consumer
/// fetches the text over its own transport and calls ``parse(_:)``.
public enum ServiceDirectory {
    /// Parses directory `text` into entries. Accepts either the raw JSON array or the full
    /// `llms.txt` markdown (the fenced ```` ```json ```` block is extracted -- the markdown
    /// preamble may itself contain bracketed example JSON, so a naive first-`[`-to-last-`]` scan
    /// would be wrong).
    ///
    /// - Throws: ``ParseError/notJSON`` if no JSON array can be found, or a `DecodingError` if the
    ///   array is malformed.
    public static func parse(_ text: String) throws -> [ServiceDirectoryEntry] {
        let json = jsonBlock(in: text) ?? text
        guard json.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") else {
            throw ParseError.notJSON
        }
        return try JSONDecoder().decode([ServiceDirectoryEntry].self, from: Data(json.utf8))
    }

    /// A reason the directory could not be parsed.
    public enum ParseError: Error, Sendable, Hashable {
        /// No JSON array was found in the text.
        case notJSON
    }

    /// The content of the first ```` ```json … ``` ```` fenced block, or `nil` if the text carries
    /// no such fence (a raw JSON payload). The opening tag must be followed by an ASCII fence
    /// boundary (space, tab, or line break) so a ```` ```jsonl ````/```` ```jsonc ```` block is not
    /// mistaken for it, and the closing ```` ``` ```` must begin its own line so a literal
    /// ```` ``` ```` inside a JSON string value cannot close the block early.
    private static func jsonBlock(in text: String) -> String? {
        var from = text.startIndex
        while let open = text.range(of: "```json", range: from ..< text.endIndex) {
            let after = open.upperBound
            if after == text.endIndex || isFenceBoundary(text[after]) {
                var searchFrom = after
                while let close = text.range(of: "```", range: searchFrom ..< text.endIndex) {
                    // A real closing fence sits at the start of its own line. `after` is past the
                    // 7-char opening tag, so the char before `close` always exists.
                    if text[text.index(before: close.lowerBound)] == "\n" {
                        return String(text[after ..< close.lowerBound])
                    }
                    // A mid-line ``` (e.g. inside a JSON string value): keep looking.
                    searchFrom = close.upperBound
                }
                return nil // an opening fence with no line-anchored closing fence
            }
            from = after // a longer tag like ```jsonl: keep scanning
        }
        return nil
    }

    /// The ASCII whitespace that bounds a fence's language token. A ```` ```json ```` opener counts
    /// only when `json` is followed by one of these (or by end of text). Deliberately *not*
    /// `Character.isWhitespace`, which also matches Unicode spaces (U+00A0 and kin) that a markdown
    /// renderer would not treat as an info-string boundary.
    private static func isFenceBoundary(_ char: Character) -> Bool {
        char == " " || char == "\t" || char == "\n" || char == "\r"
            || char == "\u{000B}" || char == "\u{000C}"
    }
}
