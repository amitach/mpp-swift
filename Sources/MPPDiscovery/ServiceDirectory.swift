import Foundation

/// One service in the MPP ecosystem directory (`mpp.dev/services`): an agent-payable endpoint with
/// its categories. Decoded from the directory's JSON (the `/api/services` endpoint, or the embedded
/// JSON block of `/services/llms.txt`).
///
/// Rail-agnostic: the directory entry says what a service *is* and *where* it is, not how it bills;
/// the rail and price are negotiated by the live `402` at the endpoint (which ``MPPDiscovery`` and
/// the `402` client handle). `serviceURL` is kept as the raw string and exposed as a parsed
/// ``url``,
/// so a malformed *URL* in one entry never fails decoding of the whole directory. (An entry missing
/// a required field is a structural error and does surface as a `DecodingError` for the array.)
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
    /// no such fence (a raw JSON payload). Scans line by line, so both fences are line-anchored (a
    /// markdown fence opens and closes its own line): a ```` ```json ```` in prose is never an
    /// opener, and a literal ```` ``` ```` inside a JSON string value never closes the block early.
    /// One linear pass, no repeated substring search.
    private static func jsonBlock(in text: String) -> String? {
        var inside = false
        var content: [Substring] = []
        // Split on a newline predicate, not the `"\n"` Character: a CRLF is a single grapheme
        // cluster, so splitting on `"\n"` would never match `\r\n`. Matching `\n` / `\r\n` / `\r`
        // covers all three endings and consumes the CR, leaving no trailing `\r` on a line.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: isLineBreak) {
            if inside {
                if isClosingFence(line) { return content.joined(separator: "\n") }
                content.append(line)
            } else if isJSONOpeningFence(line) {
                inside = true
            }
        }
        return nil // no opening fence, or one that was never closed
    }

    /// Whether `char` is a line break: LF, a CRLF grapheme cluster, or a bare CR.
    private static func isLineBreak(_ char: Character) -> Bool {
        char == "\n" || char == "\r\n" || char == "\r"
    }

    /// Whether `line` opens a JSON fence: up to three spaces of CommonMark indent, then ````
    /// ```json
    /// ````, then a fence boundary (so ```` ```jsonl ````/```` ```jsonc ```` is not mistaken for
    /// it).
    private static func isJSONOpeningFence(_ line: Substring) -> Bool {
        let body = trimmedFenceLine(line)
        guard body.hasPrefix("```json"), let after = body.index(
            body.startIndex, offsetBy: 7, limitedBy: body.endIndex
        ) else { return false }
        return after == body.endIndex || isFenceBoundary(body[after])
    }

    /// Whether `line` is a bare closing fence: indent, then ```` ``` ````, then nothing (a closing
    /// fence carries no info string). `trimmedFenceLine` has already removed any trailing
    /// CR/spaces.
    private static func isClosingFence(_ line: Substring) -> Bool {
        trimmedFenceLine(line) == "```"
    }

    /// `line` with up to three leading spaces (CommonMark's fence indent) and all trailing ASCII
    /// whitespace stripped, so fence classification ignores indentation and a trailing CR (`\r\n`
    /// line endings) or trailing spaces.
    private static func trimmedFenceLine(_ line: Substring) -> Substring {
        var start = line.startIndex
        var indent = 0
        while indent < 3, start < line.endIndex, line[start] == " " {
            start = line.index(after: start)
            indent += 1
        }
        var end = line.endIndex
        while end > start, isFenceBoundary(line[line.index(before: end)]) {
            end = line.index(before: end)
        }
        return line[start ..< end]
    }

    /// The ASCII whitespace that bounds a fence's language token. A ```` ```json ```` opener counts
    /// only when `json` is followed by one of these (or by end of line). Deliberately *not*
    /// `Character.isWhitespace`, which also matches Unicode spaces (U+00A0 and kin) that a markdown
    /// renderer would not treat as an info-string boundary.
    private static func isFenceBoundary(_ char: Character) -> Bool {
        char == " " || char == "\t" || char == "\n" || char == "\r"
            || char == "\u{000B}" || char == "\u{000C}"
    }
}
