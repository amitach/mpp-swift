import Foundation

/// The `mpp.json` config file: defaults the CLI falls back to when a flag (and, for some keys, an
/// env var) is absent. All keys are optional. The resolution order is flag > env > file > built-in.
struct Config: Codable {
    var account: String?
    var approve: String?
    var maxAmount: String?
    var servicesURL: String?
}

/// Loads the config from an explicit `--config` path, else `MPP_CONFIG`, else `./mpp.json` if it
/// exists; `nil` when none is found. A present-but-unreadable or malformed file is an error.
func loadConfig(explicitPath: String?, environment: [String: String]) throws -> Config? {
    let path: String?
    if let explicitPath {
        path = explicitPath
    } else if let envPath = environment["MPP_CONFIG"] {
        path = envPath
    } else {
        let cwdPath = FileManager.default.currentDirectoryPath + "/mpp.json"
        path = FileManager.default.fileExists(atPath: cwdPath) ? cwdPath : nil
    }
    guard let path else { return nil }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw CLIError.cannotLoad(path)
    }
    do {
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        throw CLIError.invalidInput("\(path): \(error)")
    }
}
