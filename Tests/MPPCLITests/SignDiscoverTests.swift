import Foundation
import MPPClient
import MPPCore
import MPPDiscovery
import Testing
@testable import mpp

private let validKey = "0x0000000000000000000000000000000000000000000000000000000000000001"

/// A `tempo` / `charge` zero-amount challenge (the proof path) as a WWW-Authenticate value.
private func tempoChargeChallengeValue() throws -> String {
    let request = EncodedJSON(json: .object([
        "amount": .string("0"),
        "methodDetails": .object(["chainId": .integer(1)]),
    ]))
    return try Challenge(
        id: "test-challenge", realm: "https://api.example.com",
        method: MethodName("tempo"), intent: .charge, request: request
    ).headerValue
}

@Suite("sign")
struct SignTests {
    @Test("signs a tempo charge challenge into a Payment header (no request sent)")
    func signsHeader() async throws {
        let signed = try await signedHeader(
            forChallengeValue: tempoChargeChallengeValue(),
            environment: ["MPP_PRIVATE_KEY": validKey]
        )
        #expect(signed.header.hasPrefix("Payment "))
        #expect(signed.challenge.method.rawValue == "tempo")
    }

    @Test("an unparseable challenge is rejected")
    func rejectsInvalidChallenge() async {
        await #expect(throws: CLIError.self) {
            _ = try await signedHeader(forChallengeValue: "not a challenge", environment: [:])
        }
    }

    @Test("no configured key cannot sign")
    func noKey() async throws {
        let value = try tempoChargeChallengeValue()
        await #expect(throws: CLIError.self) {
            _ = try await signedHeader(forChallengeValue: value, environment: [:])
        }
    }
}

@Suite("discover generate")
struct DiscoverGenerateTests {
    @Test("generates a discovery document that validates clean")
    func generatesValidDocument() throws {
        let input = """
        {"title":"Demo","version":"1.0.0","routes":[
          {"path":"/translate","method":"post","summary":"Translate",
           "requestBody":{"content":{}},
           "payment":{"offers":[{"method":"tempo","intent":"charge","amount":"1000"}]}}
        ]}
        """
        let document = try generateDiscoveryDocument(fromJSON: Data(input.utf8))
        #expect(DiscoveryValidator.validate(document).isEmpty)
    }

    @Test("an invalid HTTP method is rejected")
    func rejectsBadMethod() {
        let input = #"{"title":"x","version":"1","routes":[{"path":"/p","method":"FETCH"}]}"#
        #expect(throws: CLIError.self) {
            _ = try generateDiscoveryDocument(fromJSON: Data(input.utf8))
        }
    }

    @Test("malformed input JSON is rejected")
    func rejectsBadJSON() {
        #expect(throws: CLIError.self) {
            _ = try generateDiscoveryDocument(fromJSON: Data("not json".utf8))
        }
    }
}

@Suite("DocumentLoader")
struct DocumentLoaderTests {
    @Test("loads a local file")
    func loadsFile() async throws {
        let bytes = Data(#"{"openapi":"3.1.0"}"#.utf8)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpp-disc-\(UInt32.random(in: .min ... .max)).json")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loaded = try await DocumentLoader.load(file.path)
        #expect(loaded == bytes)
    }

    @Test("a missing file is a load error")
    func missingFile() async {
        await #expect(throws: CLIError.self) {
            _ = try await DocumentLoader.load("/no/such/path/does-not-exist.json")
        }
    }
}

@Suite("sign/discover exit codes")
struct SignDiscoverExitCodeTests {
    @Test("the new errors map to their curl/mppx codes")
    func exitCodes() {
        #expect(CLIOutcome(error: CLIError.invalidChallenge("x")).exitCode == 2)
        #expect(CLIOutcome(error: CLIError.noMethodForChallenge).exitCode == 75)
        #expect(CLIOutcome(error: CLIError.cannotLoad("x")).exitCode == 2)
        #expect(CLIOutcome(error: CLIError.invalidInput("x")).exitCode == 2)
        #expect(CLIOutcome(error: CLIError.discoveryInvalid(3)).exitCode == 1)
    }
}
