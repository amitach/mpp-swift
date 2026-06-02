import ArgumentParser
import Foundation
import MPPAuth

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// `mpp services`: browse an MPP services registry. A generic client - it fetches the registry URL
/// (flag > MPP_SERVICES_URL > config > default) and works on whatever compatible JSON it returns
/// (a top-level array of service objects, or `{ "services": [...] }`), without pinning a schema.
struct Services: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "services",
        abstract: "Browse an MPP services registry.",
        subcommands: [ServicesList.self, ServicesShow.self, ServicesEndpoints.self]
    )
}

/// One service in the registry listing. Tolerant: only `id` is required; unknown fields are
/// ignored.
struct RegistryEntry: Decodable {
    let id: String
    let name: String?
    let description: String?
}

struct ServicesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List registered services."
    )
    @Option(
        name: .customLong("url"),
        help: "Registry URL (overrides env / config)."
    ) var url: String?
    @Option(
        name: [.customShort("c"), .customLong("config")],
        help: "Config file path."
    ) var config: String?
    @Option(
        name: [.customShort("q"), .customLong("query")],
        help: "Filter by id / name / description."
    )
    var query: String?

    func run() async throws {
        try await runServices {
            let data = try await fetchRegistry(resolveServicesURL(urlFlag: url, configPath: config))
            for entry in try parseServices(data) where matches(query, entry) {
                print("\(displaySafe(entry.id))\t\(displaySafe(entry.name ?? ""))")
            }
        }
    }
}

struct ServicesShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one service."
    )
    @Argument(help: "The service id.") var id: String
    @Option(
        name: .customLong("url"),
        help: "Registry URL (overrides env / config)."
    ) var url: String?
    @Option(
        name: [.customShort("c"), .customLong("config")],
        help: "Config file path."
    ) var config: String?

    func run() async throws {
        try await runServices {
            let data = try await fetchRegistry(resolveServicesURL(urlFlag: url, configPath: config))
            guard let object = try serviceObject(in: data, id: id) else {
                throw CLIError.invalidInput("no service with id '\(id)'")
            }
            try FileHandle.standardOutput.write(prettyJSON(object))
        }
    }
}

struct ServicesEndpoints: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "endpoints", abstract: "Show a service's endpoints."
    )
    @Argument(help: "The service id.") var id: String
    @Option(
        name: .customLong("url"),
        help: "Registry URL (overrides env / config)."
    ) var url: String?
    @Option(
        name: [.customShort("c"), .customLong("config")],
        help: "Config file path."
    ) var config: String?

    func run() async throws {
        try await runServices {
            let data = try await fetchRegistry(resolveServicesURL(urlFlag: url, configPath: config))
            guard let object = try serviceObject(in: data, id: id) else {
                throw CLIError.invalidInput("no service with id '\(id)'")
            }
            try FileHandle.standardOutput.write(prettyJSON(object["endpoints"] ?? object))
        }
    }
}

// MARK: - Shared helpers

private let defaultServicesURL = "https://mpp.dev/api/services"

/// Resolves the registry URL: flag > MPP_SERVICES_URL env > config `servicesURL` > built-in
/// default.
func resolveServicesURL(urlFlag: String?, configPath: String?) throws -> String {
    // Short-circuit higher-precedence tiers so an explicit flag / env value is honored even when a
    // (lower-precedence) config file is absent or malformed.
    if let urlFlag { return urlFlag }
    let environment = ProcessInfo.processInfo.environment
    if let fromEnv = environment["MPP_SERVICES_URL"] { return fromEnv }
    let config = try loadConfig(explicitPath: configPath, environment: environment)
    return config?.servicesURL ?? defaultServicesURL
}

func fetchRegistry(_ urlString: String) async throws -> Data {
    guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { throw CLIError.cannotLoad(urlString) }
    do {
        return try await URLSession.shared.data(from: url).0
    } catch {
        throw CLIError.cannotLoad(urlString)
    }
}

/// Decodes the registry listing tolerantly: a top-level array, or a `{ "services": [...] }`
/// wrapper.
func parseServices(_ data: Data) throws -> [RegistryEntry] {
    let decoder = JSONDecoder()
    if let entries = try? decoder.decode([RegistryEntry].self, from: data) { return entries }
    if let wrapper = try? decoder
        .decode(ServicesWrapper.self, from: data) { return wrapper.services }
    throw CLIError.invalidInput("unrecognized services registry response")
}

struct ServicesWrapper: Decodable { let services: [RegistryEntry] }

/// Finds a service object by `id` in the raw registry JSON (via JSONSerialization, so
/// floating-point
/// or other fields anywhere in the document do not trip the integer-only JSONValue).
func serviceObject(in data: Data, id: String) throws -> [String: Any]? {
    // A malformed registry throws (a distinct, clear failure), rather than a misleading
    // "no service with id" the caller would otherwise report.
    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw CLIError.invalidInput("unrecognized services registry response")
    }
    let array: [Any]
    if let topArray = root as? [Any] {
        array = topArray
    } else if let object = root as? [String: Any], let services = object["services"] as? [Any] {
        array = services
    } else {
        return nil
    }
    return array.compactMap { $0 as? [String: Any] }.first { ($0["id"] as? String) == id }
}

private func prettyJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
    )
}

private func matches(_ query: String?, _ entry: RegistryEntry) -> Bool {
    guard let query = query?.lowercased(), !query.isEmpty else { return true }
    let haystack = [entry.id, entry.name, entry.description].compactMap { $0?.lowercased() }
    return haystack.contains { $0.contains(query) }
}

private func runServices(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let exit as ExitCode {
        throw exit
    } catch {
        let outcome = CLIOutcome(error: error)
        FileHandle.standardError.write(Data((outcome.message + "\n").utf8))
        throw ExitCode(outcome.exitCode)
    }
}
