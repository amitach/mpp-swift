import ArgumentParser
import Foundation
import MPPClient
import MPPCore

/// `mpp sign`: turn a Payment challenge into the `Authorization: Payment` header value, without
/// sending a request.
///
/// A local prepare step (mppx-style): building the credential here is deliberately NOT gated by a
/// `PaymentAuthorizer` - running `sign` IS the intent, and nothing is sent or settled until the
/// header is later presented. (The consent gate lives on the `pay` path, where a request is made.)
struct Sign: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Sign a Payment challenge into an Authorization header (sends no request)."
    )

    @Option(name: .customLong("challenge"), help: "The WWW-Authenticate: Payment challenge value.")
    var challenge: String

    @Flag(name: .customLong("dry-run"), help: "Parse and validate the challenge without signing.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Emit a JSON result instead of plain text.")
    var json = false

    func run() async throws {
        do {
            try await execute()
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
        let challenges = Challenge.challenges(inHeaderValue: challenge)
        guard !challenges.isEmpty else { throw CLIError.invalidChallenge(challenge) }

        if dryRun {
            emitDryRun(challenges)
            return
        }
        let signed = try await signedHeader(
            forChallengeValue: challenge, environment: ProcessInfo.processInfo.environment
        )
        if json {
            emitJSON(SignResult(
                authorization: signed.header,
                method: signed.challenge.method.rawValue,
                intent: signed.challenge.intent.rawValue,
                challengeId: signed.challenge.id
            ))
        } else {
            print(signed.header)
        }
    }

    private func emitDryRun(_ challenges: [Challenge]) {
        if json {
            emitJSON(DryRunResult(challenges: challenges.map {
                DryRunResult.Item(
                    method: $0.method.rawValue, intent: $0.intent.rawValue,
                    challengeId: $0.id, realm: $0.realm
                )
            }))
        } else {
            // method / intent are grammar-validated (inert) so they are safe on a terminal; the
            // realm / id (possibly server-derived) are emitted only in --json, where the encoder
            // escapes any control character.
            for challenge in challenges {
                print("valid: \(challenge.method.rawValue)/\(challenge.intent.rawValue)")
            }
        }
    }
}

/// Parses `value`, selects a configured method that supports a parsed challenge, and builds the
/// credential's `Authorization: Payment` header value (a local prepare op: no authorizer, no
/// request). Returns the header and the selected challenge. The testable core of `sign`.
func signedHeader(
    forChallengeValue value: String,
    environment: [String: String]
) async throws -> (header: String, challenge: Challenge) {
    let challenges = Challenge.challenges(inHeaderValue: value)
    guard !challenges.isEmpty else { throw CLIError.invalidChallenge(value) }
    let methods = try ClientKeyLoader.methods(from: environment)
    guard let selection = selectPaymentMethod(for: challenges, from: methods) else {
        throw methods.isEmpty ? CLIError.noPaymentMethod : CLIError.noMethodForChallenge
    }
    let header = try await selection.method.buildCredential(for: selection.challenge).headerValue
    return (header, selection.challenge)
}

private struct SignResult: Encodable {
    let authorization: String
    let method: String
    let intent: String
    let challengeId: String
}

private struct DryRunResult: Encodable {
    struct Item: Encodable {
        let method: String
        let intent: String
        let challengeId: String
        let realm: String
    }

    let challenges: [Item]
}
