import Foundation

/// A path pattern matched against an upstream request path, segment by segment.
///
/// The grammar is intentionally small (a proxy gates a known set of endpoints, it is not a general
/// router): a pattern is a `/`-separated list of segments, each either a literal, a single-segment
/// capture (`{name}` or `:name`), a single-segment wildcard (`*`), or a trailing rest-of-path
/// wildcard (`**`, only valid as the final segment). Capture and wildcard spellings follow the
/// Hummingbird router so a pattern reads the same in the engine and in the `MPPHummingbird`
/// binding.
public struct RoutePattern: Sendable, Hashable {
    /// One segment of a pattern.
    enum Segment: Hashable {
        /// A fixed path segment that must match exactly.
        case literal(String)
        /// A single segment captured under a name (`{name}` / `:name`).
        case capture(String)
        /// A single segment that matches any value but is not captured (`*`).
        case wildcard
        /// The final segment, matching the entire remaining path (`**`).
        case rest
    }

    let segments: [Segment]
    /// The raw pattern string, kept for discovery rendering and diagnostics.
    public let raw: String

    /// Parses a pattern such as `/v1/chat/completions`, `/v1/users/{id}`, or `/files/**`.
    ///
    /// A leading slash is optional and ignored; an empty path (`/`) is the empty segment list,
    /// which matches only the service root. `**` is accepted only as the final segment.
    public init(_ raw: String) throws {
        self.raw = raw
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var parsed: [Segment] = []
        for (index, part) in parts.enumerated() {
            let segment = try Self.segment(part)
            if case .rest = segment, index != parts.count - 1 {
                throw ParseError.restNotFinal(raw)
            }
            parsed.append(segment)
        }
        segments = parsed
    }

    private static func segment(_ part: String) throws -> Segment {
        if part == "**" { return .rest }
        if part == "*" { return .wildcard }
        if part.hasPrefix(":"), part.count > 1 { return .capture(String(part.dropFirst())) }
        if part.hasPrefix("{"), part.hasSuffix("}"), part.count > 2 {
            return .capture(String(part.dropFirst().dropLast()))
        }
        guard !part.contains("{"),
              !part.contains("}") else { throw ParseError.malformedSegment(part) }
        return .literal(part)
    }

    /// A reason a pattern string could not be parsed.
    public enum ParseError: Error, Sendable, Hashable {
        /// A `**` rest-wildcard appeared before the final segment.
        case restNotFinal(String)
        /// A segment used `{`/`}` outside a well-formed `{name}` capture.
        case malformedSegment(String)
    }

    /// Matches `pathSegments` (the already-split upstream path) against this pattern, returning the
    /// captured parameters on success or `nil` on no match. A `**` consumes all remaining segments.
    func match(_ pathSegments: [String]) -> [String: String]? {
        var captures: [String: String] = [:]
        var index = 0
        for segment in segments {
            switch segment {
            case let .literal(value):
                guard index < pathSegments.count, pathSegments[index] == value else { return nil }
                index += 1
            case let .capture(name):
                guard index < pathSegments.count else { return nil }
                captures[name] = pathSegments[index]
                index += 1
            case .wildcard:
                guard index < pathSegments.count else { return nil }
                index += 1
            case .rest:
                return captures
            }
        }
        return index == pathSegments.count ? captures : nil
    }

    /// The OpenAPI-path rendering of this pattern: captures become `{name}`, wildcards are rendered
    /// literally (`*` / `**`) since OpenAPI has no wildcard concept but the path is still a stable
    /// identifier. Used to advertise the route in the discovery document.
    func openAPIPath() -> String {
        let rendered = segments.map { segment -> String in
            switch segment {
            case let .literal(value): value
            case let .capture(name): "{\(name)}"
            case .wildcard: "*"
            case .rest: "**"
            }
        }
        return "/" + rendered.joined(separator: "/")
    }
}
