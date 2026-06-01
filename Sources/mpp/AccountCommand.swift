import ArgumentParser
import Foundation
import MPPAuth
import MPPEVM

/// The testable core of the `account` commands over an injected ``AccountStore``. Key generation
/// and address derivation (which need MPPEVM) live here; the store stays crypto-free.
struct AccountManager {
    let store: any AccountStore

    /// Generates a new secp256k1 key, stores it under `name` (label = its address), returns the
    /// checksummed address.
    func create(name: String) throws -> String {
        try Self.validate(name)
        if try store.accounts().contains(where: { $0.name == name }) {
            throw CLIError.accountExists(name)
        }
        let (key, address) = try Self.generateKey()
        try store.store(key, name: name, label: address)
        return address
    }

    func list() throws -> (accounts: [Account], defaultName: String?) {
        try (accounts: store.accounts(), defaultName: store.defaultName())
    }

    func address(name: String) throws -> String {
        guard let account = try store.accounts().first(where: { $0.name == name }) else {
            throw AccountStoreError.notFound(name)
        }
        return account.label
    }

    /// Exports the private key (hex). Reads the key, so it may prompt for authentication.
    func exportKeyHex(name: String) throws -> String {
        try store.privateKey(name: name).hexPrefixed
    }

    func delete(name: String) throws {
        guard try store.accounts().contains(where: { $0.name == name }) else {
            throw AccountStoreError.notFound(name)
        }
        try store.delete(name: name)
        if try store.defaultName() == name { try store.setDefaultName(nil) }
    }

    func setDefault(name: String) throws {
        guard try store.accounts().contains(where: { $0.name == name }) else {
            throw AccountStoreError.notFound(name)
        }
        try store.setDefaultName(name)
    }

    func defaultName() throws -> String? {
        try store.defaultName()
    }

    /// A random valid key + its checksummed address (the secp256k1 order is so close to 2^256 that
    /// a random scalar is valid with overwhelming probability; a few retries make it certain).
    private static func generateKey() throws -> (key: Data, address: String) {
        for _ in 0 ..< 8 {
            let key = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
            guard let signer = try? Secp256k1Signer(privateKey: key),
                  let address = EthereumAddress(uncompressedPublicKey: signer.publicKey)
            else { continue }
            return (key, address.checksummed)
        }
        throw CLIError.invalidPrivateKey
    }

    private static func validate(_ name: String) throws {
        let valid = !name.isEmpty && name.count <= 64
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard valid else { throw CLIError.invalidAccountName(name) }
    }
}

/// `mpp account`: manage stored payer accounts (macOS Keychain; unsupported on platforms with no
/// secure key store, where `MPP_PRIVATE_KEY` is used instead). Named `AccountCommand` (not
/// `Account`) to avoid shadowing ``MPPAuth/Account``.
struct AccountCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "account",
        abstract: "Manage stored payer accounts (macOS Keychain).",
        subcommands: [
            AccountCreate.self, AccountList.self, AccountView.self,
            AccountDefault.self, AccountDelete.self, AccountExport.self, AccountFund.self,
        ]
    )
}

struct AccountCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new account."
    )
    @Argument(help: "The account name (letters, digits, - and _).") var name: String
    func run() throws {
        try withAccountManager { try print($0.create(name: name)) }
    }
}

struct AccountList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List accounts.")
    func run() throws {
        try withAccountManager { manager in
            let (accounts, defaultName) = try manager.list()
            for account in accounts {
                let marker = account.name == defaultName ? " (default)" : ""
                print("\(account.name)\t\(account.label)\(marker)")
            }
        }
    }
}

struct AccountView: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Show an account's address."
    )
    @Argument(help: "The account name.") var name: String
    func run() throws {
        try withAccountManager { try print($0.address(name: name)) }
    }
}

struct AccountDefault: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "default", abstract: "Show or set the default account."
    )
    @Argument(help: "The account to make default; omit to show the current default.")
    var name: String?
    func run() throws {
        try withAccountManager { manager in
            if let name {
                try manager.setDefault(name: name)
            } else if let current = try manager.defaultName() {
                print(current)
            }
        }
    }
}

struct AccountDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an account."
    )
    @Argument(help: "The account name.") var name: String
    func run() throws {
        try withAccountManager { try $0.delete(name: name) }
    }
}

struct AccountExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Print an account's private key (prompts for authentication)."
    )
    @Argument(help: "The account name.") var name: String
    func run() throws {
        try withAccountManager { try print($0.exportKeyHex(name: name)) }
    }
}

struct AccountFund: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fund", abstract: "(Unsupported) fund an account from a faucet."
    )
    @Argument(help: "The account name.") var name: String
    func run() throws {
        FileHandle.standardError.write(Data(
            ("Funding is not supported by mpp. Use the Tempo faucet "
                + "(Moderato: tempo_fundAddress) for the account's address.\n").utf8
        ))
        throw ExitCode(2)
    }
}

/// Resolves the platform account store (or fails with `accountsUnsupported`), runs `body` over an
/// ``AccountManager``, and maps any error to a printed message + exit code.
private func withAccountManager(_ body: (AccountManager) throws -> Void) throws {
    do {
        guard let store = makeAccountStore() else { throw CLIError.accountsUnsupported }
        try body(AccountManager(store: store))
    } catch let exit as ExitCode {
        throw exit
    } catch {
        let outcome = CLIOutcome(error: error)
        FileHandle.standardError.write(Data((outcome.message + "\n").utf8))
        throw ExitCode(outcome.exitCode)
    }
}
