import ArgumentParser
import Foundation

/// `mpp init`: write a starter `mpp.json` config file (the keys the CLI reads, with safe defaults).
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Write a starter mpp.json config file."
    )

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: "Path to write (default ./mpp.json)."
    )
    var output = "mpp.json"

    @Flag(name: [.customShort("f"), .customLong("force")], help: "Overwrite an existing file.")
    var force = false

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
        if FileManager.default.fileExists(atPath: output), !force {
            throw CLIError.invalidInput("\(output) already exists; pass --force to overwrite.")
        }
        // A JSON template (JSON has no comments). null/example values document the keys the CLI
        // reads; flags and env vars still override these. `approve` is left null on purpose: a
        // null defers to the context-aware default (a prompt when interactive, fail-closed
        // headless), so writing a starter config never silently downgrades the interactive
        // default to no-prompt. Valid values (auto / tty / biometric) are in `pay --help`.
        let template = """
        {
          "account": null,
          "approve": null,
          "maxAmount": null,
          "servicesURL": "https://mpp.dev/api/services"
        }
        """
        try Data((template + "\n").utf8).write(to: URL(fileURLWithPath: output))
        FileHandle.standardError.write(Data("Wrote \(output)\n".utf8))
    }
}
