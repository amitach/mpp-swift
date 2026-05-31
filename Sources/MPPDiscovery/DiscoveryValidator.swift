import Foundation

/// A single discovery-document validation problem.
public struct DiscoveryValidationError: Sendable, Hashable {
    /// Whether the problem violates a `MUST` (error) or a `SHOULD` (warning) of the spec.
    public enum Severity: Sendable, Hashable {
        case error
        case warning
    }

    /// A human-readable description of the problem.
    public let message: String
    /// Dotted JSON path to the problem (for example
    /// `paths./x.get.x-payment-info.offers[0].amount`), or `(root)`.
    public let path: String
    /// The severity. Structural and `MUST` violations are `.error`; `SHOULD` violations are
    /// `.warning`.
    public let severity: Severity

    public init(message: String, path: String, severity: Severity = .error) {
        self.message = message
        self.path = path
        self.severity = severity
    }
}

/// Validates a discovery document and returns the problems found.
public enum DiscoveryValidator {
    /// Validates the raw JSON of a discovery document, structurally and semantically (an empty
    /// result means valid). Structural problems short-circuit (a malformed document cannot be
    /// meaningfully checked semantically); otherwise the semantic checks run.
    public static func validate(_ json: Data) -> [DiscoveryValidationError] {
        let structural = structuralErrors(json)
        guard structural.isEmpty else { return structural }
        return semanticErrors(json)
    }

    private static func structuralErrors(_ json: Data) -> [DiscoveryValidationError] {
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

    private static let httpMethods: Set<String> = [
        "get", "put", "post", "delete", "options", "head", "patch", "trace",
    ]

    /// Spec semantic checks per payment-gated operation: a `402` response is REQUIRED (error), a
    /// `requestBody` is RECOMMENDED (warning). Walks the raw JSON (the parsed `DiscoveryDocument`
    /// projects away `responses` / `requestBody`); uses JSONSerialization so a number anywhere in
    /// an OpenAPI schema does not trip the integer-only `JSONValue`. Sorted for determinism.
    private static func semanticErrors(_ json: Data) -> [DiscoveryValidationError] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let paths = root["paths"] as? [String: Any]
        else { return [] }

        var errors: [DiscoveryValidationError] = []
        for (path, item) in paths {
            guard let methods = item as? [String: Any] else { continue }
            for (method, value) in methods where httpMethods.contains(method.lowercased()) {
                guard let operation = value as? [String: Any],
                      operation["x-payment-info"] != nil
                else { continue }
                let opPath = "paths.\(path).\(method)"
                let responses = operation["responses"] as? [String: Any]
                if responses?["402"] == nil {
                    errors.append(DiscoveryValidationError(
                        message: "Operation with x-payment-info MUST have a 402 response",
                        path: "\(opPath).responses", severity: .error
                    ))
                }
                if operation["requestBody"] == nil {
                    errors.append(DiscoveryValidationError(
                        message: "Operation with x-payment-info SHOULD define a requestBody",
                        path: opPath, severity: .warning
                    ))
                }
            }
        }
        return errors.sorted { ($0.path, $0.message) < ($1.path, $1.message) }
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
