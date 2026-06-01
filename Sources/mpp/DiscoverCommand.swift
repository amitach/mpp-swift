import ArgumentParser
import Foundation
import MPPAuth
import MPPCore
import MPPDiscovery

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// `mpp discover`: validate or generate an MPP / OpenAPI discovery document.
struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Validate or generate an MPP / OpenAPI discovery document.",
        subcommands: [DiscoverValidate.self, DiscoverGenerate.self]
    )
}

/// `mpp discover validate <file|url>`: load a discovery document and report any problems. Exits
/// non-zero (1) if it has `error`-severity problems; warnings do not fail.
struct DiscoverValidate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a discovery document from a file path or http(s) URL."
    )

    @Argument(help: "A file path or http(s) URL of the discovery document.")
    var source: String

    @Flag(name: .customLong("json"), help: "Emit a JSON result instead of plain text.")
    var json = false

    func run() async throws {
        do {
            try await execute()
        } catch let exit as ExitCode {
            // execute() already emitted the validation result; this just sets the exit code,
            // so do NOT emit a second (error) envelope.
            throw exit
        } catch {
            let outcome = CLIOutcome(error: error)
            if json {
                JSONOutput(
                    succeeded: false, status: 0, body: nil, receipt: nil,
                    error: .init(code: outcome.code, exitCode: outcome.exitCode)
                ).emit()
            } else {
                FileHandle.standardError.write(Data((outcome.message + "\n").utf8))
            }
            throw ExitCode(outcome.exitCode)
        }
    }

    private func execute() async throws {
        let data = try await DocumentLoader.load(source)
        let problems = DiscoveryValidator.validate(data)
        let errors = problems.filter { $0.severity == .error }
        if json {
            emitJSON(ValidateResult(valid: errors.isEmpty, problems: problems.map {
                ValidateResult.Problem(
                    message: $0.message, path: $0.path,
                    severity: $0.severity == .error ? "error" : "warning"
                )
            }))
        } else {
            // The validator message and JSON path can echo document-derived text, so sanitize them
            // before printing to the terminal (the --json encoder escapes them on its own).
            for problem in problems {
                let tag = problem.severity == .error ? "error" : "warning"
                let line = "\(tag) \(displaySafe(problem.path, maxLength: 200)): "
                    + displaySafe(problem.message, maxLength: 200)
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            if errors.isEmpty { print("valid") }
        }
        // The result is already emitted above; throw a bare ExitCode (passed through by run())
        // so an invalid document exits 1 without a second output.
        if !errors.isEmpty { throw ExitCode(1) }
    }
}

/// `mpp discover generate <input.json>`: build a discovery document from a JSON service description
/// (the CLI-local input below), reusing ``DiscoveryGenerator``.
struct DiscoverGenerate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate a discovery document from a JSON service description."
    )

    @Argument(help: "Path to a JSON file: { title, version, routes: [...], serviceInfo? }.")
    var input: String

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: "Write to a file instead of stdout."
    )
    var output: String?

    func run() throws {
        do {
            try execute()
        } catch {
            let outcome = CLIOutcome(error: error)
            FileHandle.standardError.write(Data((outcome.message + "\n").utf8))
            throw ExitCode(outcome.exitCode)
        }
    }

    private func execute() throws {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: input))
        } catch {
            throw CLIError.cannotLoad(input)
        }
        let encoded = try generateDiscoveryDocument(fromJSON: data)
        if let output {
            try encoded.write(to: URL(fileURLWithPath: output))
        } else {
            FileHandle.standardOutput.write(encoded)
        }
    }
}

/// Decodes a ``GenerateInput`` JSON description, maps it onto ``DiscoveryGenerator``, and returns
/// the pretty-printed discovery-document JSON. The testable core of `discover generate`.
func generateDiscoveryDocument(fromJSON data: Data) throws -> Data {
    let spec: GenerateInput
    do {
        spec = try JSONDecoder().decode(GenerateInput.self, from: data)
    } catch {
        throw CLIError.invalidInput("\(error)")
    }
    let routes = try spec.routes.map { try $0.toRoute() }
    let document = try DiscoveryGenerator.generate(
        info: DiscoveryDocument.Info(title: spec.title, version: spec.version),
        routes: routes, serviceInfo: spec.serviceInfo
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(document)
}

/// The CLI-local input for `discover generate`: the parameters of ``DiscoveryGenerator/generate``,
/// in JSON (`DiscoveryRoute` itself is not `Codable`, so this thin model maps onto it).
private struct GenerateInput: Decodable {
    struct Route: Decodable {
        let path: String
        let method: String
        let payment: PaymentInfo?
        let summary: String?
        let requestBody: JSONValue?

        func toRoute() throws -> DiscoveryRoute {
            guard let httpMethod = HTTPMethod(rawValue: method.lowercased()) else {
                throw CLIError.invalidMethod(method)
            }
            return DiscoveryRoute(
                path: path, method: httpMethod, payment: payment,
                requestBody: requestBody, summary: summary
            )
        }
    }

    let title: String
    let version: String
    let routes: [Route]
    let serviceInfo: ServiceInfo?
}

private struct ValidateResult: Encodable {
    struct Problem: Encodable {
        let message: String
        let path: String
        let severity: String
    }

    let valid: Bool
    let problems: [Problem]
}

/// Loads a discovery document's bytes from a file path or an http(s) URL.
enum DocumentLoader {
    static func load(_ source: String) async throws -> Data {
        if let url = URL(string: source), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            do {
                return try await URLSession.shared.data(from: url).0
            } catch {
                throw CLIError.cannotLoad(source)
            }
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: source))
        } catch {
            throw CLIError.cannotLoad(source)
        }
    }
}
