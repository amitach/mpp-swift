import Foundation

/// A single discovery-document validation problem (always an error in this
/// release; warning-level semantic checks land with the operation-level
/// validations).
public struct DiscoveryValidationError: Sendable, Hashable {
    /// A human-readable description of the problem.
    public let message: String
    /// Dotted JSON path to the problem (for example
    /// `paths./x.get.x-payment-info.offers[0].amount`), or `(root)`.
    public let path: String

    public init(message: String, path: String) {
        self.message = message
        self.path = path
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
        } catch let error as ServiceDocs.DecodingFailure {
            return one("\(error)", at: "x-service-info.docs")
        } catch {
            return one("\(error)", at: "(root)")
        }
    }

    private static func one(_ message: String, at path: String) -> [DiscoveryValidationError] {
        [DiscoveryValidationError(message: message, path: path)]
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
            return DiscoveryValidationError(message: "\(error)", path: "(root)")
        }
        let path = context.codingPath.map { key in
            if let index = key.intValue { "[\(index)]" } else { key.stringValue }
        }.joined(separator: ".")
        return DiscoveryValidationError(
            message: context.debugDescription,
            path: path.isEmpty ? "(root)" : path
        )
    }
}
