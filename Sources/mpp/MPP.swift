import ArgumentParser
import Foundation

/// The `mpp` command tree. Today it pays a 402-protected URL; sign / discover / account / services
/// / --mcp arrive in later workstream PRs.
struct MPP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mpp",
        abstract: "Pay for 402-protected HTTP resources from the command line.",
        version: "0.1.0",
        subcommands: [Pay.self, Sign.self, Discover.self]
    )
}

/// The process entry point. It drives `MPP` directly (rather than `MPP.main()`) so a usage / parse
/// error exits 2 (curl / mppx parity), while `--help` / `--version` still exit 0; a command's own
/// `ExitCode` (the payment outcome) is passed through unchanged.
@main
enum MPPMain {
    static func main() async {
        do {
            var command = try MPP.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let exit as ExitCode {
            Foundation.exit(exit.rawValue)
        } catch {
            if MPP.exitCode(for: error) == .success {
                // --help / --version: ArgumentParser prints to stdout and exits 0.
                MPP.exit(withError: error)
            }
            FileHandle.standardError.write(Data((MPP.fullMessage(for: error) + "\n").utf8))
            Foundation.exit(2)
        }
    }
}
