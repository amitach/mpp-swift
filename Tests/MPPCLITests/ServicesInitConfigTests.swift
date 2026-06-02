import Foundation
import Testing
@testable import mpp

private func tempFile(_ contents: String, suffix: String = ".json") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mpp-test-\(UInt32.random(in: .min ... .max))\(suffix)")
    try Data(contents.utf8).write(to: url)
    return url
}

@Suite("Config loading")
struct ConfigLoadingTests {
    @Test("loads an explicit config path")
    func explicit() throws {
        let file = try tempFile(#"{"account":"alice","maxAmount":"500"}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let config = try loadConfig(explicitPath: file.path, environment: [:])
        #expect(config?.account == "alice")
        #expect(config?.maxAmount == "500")
    }

    @Test("loads from MPP_CONFIG when no explicit path")
    func fromEnv() throws {
        let file = try tempFile(#"{"approve":"tty"}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let config = try loadConfig(explicitPath: nil, environment: ["MPP_CONFIG": file.path])
        #expect(config?.approve == "tty")
    }

    @Test("a missing explicit config is an error")
    func missing() {
        #expect(throws: CLIError.self) {
            _ = try loadConfig(explicitPath: "/no/such/mpp.json", environment: [:])
        }
    }

    @Test("a malformed config is an error")
    func malformed() throws {
        let file = try tempFile("not json")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: CLIError.self) {
            _ = try loadConfig(explicitPath: file.path, environment: [:])
        }
    }
}

@Suite("services registry parsing")
struct ServicesParsingTests {
    @Test("parses a top-level array and a {services:[...]} wrapper")
    func arrayAndWrapper() throws {
        let array = Data(#"[{"id":"svc1","name":"One"},{"id":"svc2"}]"#.utf8)
        #expect(try parseServices(array).map(\.id) == ["svc1", "svc2"])
        let wrapper = Data(#"{"services":[{"id":"a"}]}"#.utf8)
        #expect(try parseServices(wrapper).map(\.id) == ["a"])
    }

    @Test("an unrecognized registry response is an error")
    func unrecognized() {
        #expect(throws: CLIError.self) {
            _ = try parseServices(Data(#"{"nope":true}"#.utf8))
        }
    }

    @Test("finds a service object by id (float fields and all) and nil for unknown")
    func findObject() throws {
        // The 1.5 float verifies JSONSerialization (not the integer-only JSONValue) backs lookup.
        let data = Data(#"[{"id":"svc1","price":1.5,"endpoints":["/a"]},{"id":"svc2"}]"#.utf8)
        let object = try serviceObject(in: data, id: "svc1")
        #expect(object?["id"] as? String == "svc1")
        #expect(try serviceObject(in: data, id: "ghost") == nil)
    }
}

@Suite("init")
struct InitTests {
    @Test("init writes a config file that decodes back to Config")
    func writesValidConfig() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpp-init-\(UInt32.random(in: .min ... .max)).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var command = InitCommand()
        command.output = file.path
        command.force = true
        try command.run()
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: file))
        #expect(config.approve == "auto")
        #expect(config.servicesURL == "https://mpp.dev/api/services")
    }
}
