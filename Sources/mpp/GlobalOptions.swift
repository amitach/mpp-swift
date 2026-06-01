import ArgumentParser

/// Curl-like request options shared by the request-issuing commands (today: `pay`).
struct GlobalOptions: ParsableArguments {
    @Option(
        name: [.customShort("X"), .customLong("method")],
        help: "HTTP method to use (default GET)."
    )
    var method: String?

    @Option(
        name: [.customShort("H"), .customLong("header")],
        help: "Add a request header, 'Name: Value' (repeatable)."
    )
    var headers: [String] = []

    @Option(
        name: [.customShort("d"), .customLong("data")],
        help: "Send this request body."
    )
    var data: String?

    @Flag(
        name: .customLong("json"),
        help: "Emit a JSON result on stdout instead of the raw response."
    )
    var json = false

    @Flag(name: [.customShort("v"), .customLong("verbose")], help: "Print flow progress to stderr.")
    var verbose = false

    @Flag(
        name: [.customShort("f"), .customLong("fail")],
        help: "Exit non-zero (22) if the server returns an HTTP error status."
    )
    var fail = false

    @Flag(
        name: [.customShort("s"), .customLong("silent")],
        help: "Suppress progress and error text."
    )
    var silent = false

    @Flag(
        name: [.customShort("k"), .customLong("insecure")],
        help: "Allow a non-https URL for a loopback host (local testing only)."
    )
    var insecure = false

    @Option(
        name: [.customShort("a"), .customLong("account")],
        help: "Use a stored account's key (macOS Keychain) instead of MPP_PRIVATE_KEY."
    )
    var account: String?
}
