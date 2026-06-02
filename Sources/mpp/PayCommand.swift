import ArgumentParser
import Foundation
import HTTPTypes
import HTTPTypesFoundation
import MPPAuth
import MPPClient
import MPPCore

/// A short, terminal-safe progress line for a `--verbose` run. Method / intent are
/// grammar-validated
/// (inert); the server-controlled `realm` and the receipt reference are sanitized via
/// `displaySafe`.
func verboseLine(for event: ClientEvent) -> String {
    switch event {
    case let .challengeReceived(challenge):
        "* challenge \(challenge.method.rawValue)/\(challenge.intent.rawValue) from "
            + displaySafe(challenge.realm, maxLength: 120)
    case .credentialCreated:
        "* credential built"
    case let .paymentResponse(receipt):
        receipt.map { "* paid; receipt " + displaySafe($0.reference, maxLength: 120) }
            ?? "* response received"
    case let .paymentFailed(error):
        "* payment failed (\(error))"
    }
}

/// Collects the receipt from the client's event stream (the HTTP flow surfaces it via `onEvent`,
/// not the return value). Synchronous, lock-guarded: `onEvent` is called from inside the request.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Receipt?

    func record(_ event: ClientEvent) {
        guard case let .paymentResponse(receipt) = event else { return }
        lock.lock(); stored = receipt; lock.unlock()
    }

    var receipt: Receipt? {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

/// The outcome of a paid request: the paid response's status, its body, and any receipt.
struct PayResult {
    let status: Int
    let body: Data
    let receipt: Receipt?
}

/// The injected, network-free core of `pay`: send a request through a `PaymentClient` (which pays a
/// 402 transparently) and return the paid response plus any receipt. Separated from the
/// ArgumentParser command so the flow is testable over a stub transport.
struct PayRunner {
    let transport: any MPPHTTPTransport
    let authorizer: any PaymentAuthorizer
    let methods: [any PaymentMethodClient]
    let allowInsecureLocal: Bool
    let progress: (@Sendable (ClientEvent) -> Void)?

    init(
        transport: any MPPHTTPTransport,
        authorizer: any PaymentAuthorizer,
        methods: [any PaymentMethodClient],
        allowInsecureLocal: Bool,
        progress: (@Sendable (ClientEvent) -> Void)? = nil
    ) {
        self.transport = transport
        self.authorizer = authorizer
        self.methods = methods
        self.allowInsecureLocal = allowInsecureLocal
        self.progress = progress
    }

    func run(request: HTTPRequest, body: Data) async throws -> PayResult {
        let events = EventCollector()
        let forward = progress
        let client = PaymentClient(
            transport: transport,
            methods: methods,
            allowInsecureLocal: allowInsecureLocal,
            authorizer: authorizer,
            onEvent: { event in events.record(event); forward?(event) }
        )
        let (response, responseBody) = try await client.send(request, body: body)
        return PayResult(status: response.status.code, body: responseBody, receipt: events.receipt)
    }
}

/// `mpp pay <url>`: request a URL and, on a 402, pay it and print the response.
struct Pay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pay",
        abstract: "Request a URL and, on a 402 Payment Required, pay it and print the response."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "The URL to request (https, or a loopback host with --insecure).")
    var url: String

    @Option(
        name: .customLong("approve"),
        help: "Authorize via auto, tty, or biometric (default: tty if interactive, else auto)."
    )
    var approve: ApproveMode?

    @Option(
        name: .customLong("max-amount"),
        help: "Maximum amount to approve, in base units. Required for a non-interactive run."
    )
    var maxAmount: String?

    func run() async throws {
        do {
            try await execute()
        } catch {
            let outcome = CLIOutcome(error: error)
            emitError(outcome)
            throw ExitCode(outcome.exitCode)
        }
    }

    private func execute() async throws {
        let environment = ProcessInfo.processInfo.environment
        // Resolution order: flag > config file > built-in default.
        let config = try loadConfig(explicitPath: globals.config, environment: environment)
        let request = try buildRequest()
        let resolvedApprove = try Self.resolveApprove(flag: approve, configValue: config?.approve)
        let cap = try parseCap(maxAmount ?? config?.maxAmount)
        let authorizer = try AuthorizerFactory.make(
            approve: resolvedApprove, maxAmount: cap, interactive: Terminal.isInteractive
        )
        let methods = try ClientKeyLoader.methods(
            account: globals.account ?? config?.account, store: makeAccountStore(),
            environment: environment
        )
        guard !methods.isEmpty else { throw CLIError.noPaymentMethod }

        let runner = PayRunner(
            transport: URLSessionTransport(), authorizer: authorizer,
            methods: methods, allowInsecureLocal: globals.insecure, progress: progressSink()
        )
        let body = globals.data.map { Data($0.utf8) } ?? Data()
        let result = try await runner.run(request: request, body: body)

        // Check --fail before emitting, so a failing response produces a single error output
        // (the body suppressed, curl-like) rather than a success line and then an error line.
        if globals.fail, result.status >= 400 {
            throw CLIError.httpError(status: result.status)
        }
        emitSuccess(result)
    }

    /// A stderr progress printer for `--verbose` (suppressed by `--silent`), else nil.
    private func progressSink() -> (@Sendable (ClientEvent) -> Void)? {
        guard globals.verbose, !globals.silent else { return nil }
        return { event in
            FileHandle.standardError.write(Data((verboseLine(for: event) + "\n").utf8))
        }
    }

    private func buildRequest() throws -> HTTPRequest {
        guard let parsed = URL(string: url) else { throw CLIError.invalidURL(url) }
        var request = HTTPRequest(url: parsed)
        if let method = globals.method {
            guard let parsedMethod = HTTPRequest.Method(method) else {
                throw CLIError.invalidMethod(method)
            }
            request.method = parsedMethod
        }
        for header in globals.headers {
            guard let (name, value) = Self.parseHeader(header) else { continue }
            request.headerFields[name] = value
        }
        return request
    }

    /// Resolves the approve mode: the flag wins; a config value must be valid (an unrecognized one
    /// fails closed rather than being silently ignored); else nil (the factory's interactive
    /// default).
    static func resolveApprove(flag: ApproveMode?, configValue: String?) throws -> ApproveMode? {
        if let flag { return flag }
        guard let configValue else { return nil }
        guard let mode = ApproveMode(rawValue: configValue) else {
            throw CLIError.invalidInput("config 'approve' must be auto, tty, or biometric")
        }
        return mode
    }

    private func parseCap(_ value: String?) throws -> Amount? {
        guard let value else { return nil }
        do {
            return try Amount(value)
        } catch {
            throw CLIError.invalidMaxAmount(value)
        }
    }

    private func emitSuccess(_ result: PayResult) {
        if globals.json {
            JSONOutput(
                succeeded: result.status < 400,
                status: result.status,
                body: String(data: result.body, encoding: .utf8),
                receipt: JSONOutput.make(result.receipt),
                error: nil
            ).emit()
        } else {
            FileHandle.standardOutput.write(result.body)
        }
    }

    private func emitError(_ outcome: CLIOutcome) {
        if globals.json {
            JSONOutput(
                succeeded: false, status: 0, body: nil, receipt: nil,
                error: .init(code: outcome.code, exitCode: outcome.exitCode)
            ).emit()
        } else if !globals.silent {
            FileHandle.standardError.write(Data((outcome.message + "\n").utf8))
        }
    }

    /// Parses a `Name: Value` header; returns nil for a malformed header or an invalid field name.
    static func parseHeader(_ raw: String) -> (HTTPField.Name, String)? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let name = String(raw[raw.startIndex ..< colon]).trimmingCharacters(in: .whitespaces)
        let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard let fieldName = HTTPField.Name(name) else { return nil }
        return (fieldName, value)
    }
}
