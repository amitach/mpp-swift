import ArgumentParser
import Foundation
import HTTPTypes
import HTTPTypesFoundation
import MPPClient
import MPPCore

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

/// The injected, network-free core of `pay`: send a request through a `PaymentClient` (which pays a
/// 402 transparently) and return the paid response plus any receipt. Separated from the
/// ArgumentParser command so the flow is testable over a stub transport.
/// The outcome of a paid request: the paid response's status, its body, and any receipt.
struct PayResult {
    let status: Int
    let body: Data
    let receipt: Receipt?
}

struct PayRunner {
    let transport: any MPPHTTPTransport
    let authorizer: any PaymentAuthorizer
    let methods: [any PaymentMethodClient]
    let allowInsecureLocal: Bool

    func run(request: HTTPRequest, body: Data) async throws -> PayResult {
        let events = EventCollector()
        let client = PaymentClient(
            transport: transport,
            methods: methods,
            allowInsecureLocal: allowInsecureLocal,
            authorizer: authorizer,
            onEvent: { events.record($0) }
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
        let request = try buildRequest()
        let cap = try parseCap()
        let authorizer = try AuthorizerFactory.make(
            approve: approve, maxAmount: cap, interactive: Terminal.isInteractive
        )
        let methods = try ClientKeyLoader.methods(from: ProcessInfo.processInfo.environment)
        guard !methods.isEmpty else { throw CLIError.noPaymentMethod }

        let runner = PayRunner(
            transport: URLSessionTransport(), authorizer: authorizer,
            methods: methods, allowInsecureLocal: globals.insecure
        )
        let body = globals.data.map { Data($0.utf8) } ?? Data()
        let result = try await runner.run(request: request, body: body)

        emitSuccess(result)
        if globals.fail, result.status >= 400 {
            throw CLIError.httpError(status: result.status)
        }
    }

    private func buildRequest() throws -> HTTPRequest {
        guard let parsed = URL(string: url) else { throw CLIError.invalidURL(url) }
        var request = HTTPRequest(url: parsed)
        if let method = globals.method, let parsedMethod = HTTPRequest.Method(method) {
            request.method = parsedMethod
        }
        for header in globals.headers {
            guard let (name, value) = Self.parseHeader(header) else { continue }
            request.headerFields[name] = value
        }
        return request
    }

    private func parseCap() throws -> Amount? {
        guard let value = maxAmount else { return nil }
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
