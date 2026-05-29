import Foundation

/// Validates a discovery document structurally and semantically. Returns the
/// list of problems found (empty means valid). Semantic checks that the typed
/// model already enforces on decode are surfaced here as errors with a path:
/// a non-integer (for example floating-point) or otherwise malformed `amount`,
/// an empty `offers` array, offers mixed with flat fields, and an unsupported
/// `openapi` version.
/// A single discovery-document validation problem.
public struct DiscoveryValidationError: Sendable, Hashable {
    public let message: String
    /// Dotted JSON path to the problem (for example
    /// `paths./x.get.x-payment-info.amount`), or `(root)`.
    public let path: String
    public let severity: Severity
    public enum Severity: String, Sendable, Hashable { case error, warning }

    public init(message: String, path: String, severity: Severity) {
        self.message = message
        self.path = path
        self.severity = severity
    }
}

/// Validates a discovery document and returns the problems found.
public enum DiscoveryValidator {
    /// Validates the raw JSON of a discovery document (empty result means valid).
    public static func validate(_ json: Data) -> [DiscoveryValidationError] {
        do {
            _ = try JSONDecoder().decode(DiscoveryDocument.self, from: json)
            return []
        } catch let error as DecodingError {
            return [describe(error)]
        } catch let error as DiscoveryDocument.DecodingFailure {
            return one("\(error)", at: "openapi")
        } catch let error as PaymentInfo.DecodingFailure {
            return one("\(error)", at: "x-payment-info")
        } catch {
            return one("\(error)", at: "(root)")
        }
    }

    private static func one(_ message: String, at path: String) -> [DiscoveryValidationError] {
        [DiscoveryValidationError(message: message, path: path, severity: .error)]
    }

    private static func describe(_ error: DecodingError) -> DiscoveryValidationError {
        let context: DecodingError.Context
        switch error {
        case let .dataCorrupted(ctx),
             let .keyNotFound(_, ctx),
             let .typeMismatch(_, ctx),
             let .valueNotFound(_, ctx):
            context = ctx
        @unknown default:
            return DiscoveryValidationError(message: "\(error)", path: "(root)", severity: .error)
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return DiscoveryValidationError(
            message: context.debugDescription,
            path: path.isEmpty ? "(root)" : path,
            severity: .error
        )
    }
}
