import Foundation
import MPPAuth
import MPPCore
import Testing
@testable import mpp

/// An in-memory ``AccountStore`` for tests (the real `KeychainAccountStore` is macOS + biometric
/// and exercised manually). No prompts: it mirrors the protocol's secret/non-secret split only in
/// that `accounts()` returns labels without the key.
final class InMemoryAccountStore: AccountStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private var labels: [String: String] = [:]
    private var defaultAccount: String?

    func store(_ privateKey: Data, name: String, label: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys[name] = privateKey
        labels[name] = label
    }

    func privateKey(name: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[name] else { throw AccountStoreError.notFound(name) }
        return key
    }

    func accounts() throws -> [Account] {
        lock.lock(); defer { lock.unlock() }
        return keys.keys.map { Account(name: $0, label: labels[$0] ?? "") }
            .sorted { $0.name < $1.name }
    }

    func delete(name: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys[name] = nil
        labels[name] = nil
    }

    func defaultName() throws -> String? {
        lock.lock(); defer { lock.unlock() }; return defaultAccount
    }

    func setDefaultName(_ name: String?) throws {
        lock.lock(); defer { lock.unlock() }; defaultAccount = name
    }
}

private func tempoChargeChallengeValue() throws -> String {
    let request = EncodedJSON(json: .object([
        "amount": .string("0"),
        "methodDetails": .object(["chainId": .integer(1)]),
    ]))
    return try Challenge(
        id: "c", realm: "https://api.example.com",
        method: MethodName("tempo"), intent: .charge, request: request
    ).headerValue
}

@Suite("AccountManager")
struct AccountManagerTests {
    @Test("create stores a key and returns its address; view/list see it without the key")
    func createAndList() throws {
        let manager = AccountManager(store: InMemoryAccountStore())
        let address = try manager.create(name: "alice")
        #expect(address.hasPrefix("0x"))
        #expect(try manager.address(name: "alice") == address)
        let listed = try manager.list()
        #expect(listed.accounts.map(\.name) == ["alice"])
        #expect(listed.accounts.first?.label == address)
        #expect(try manager.exportKeyHex(name: "alice").hasPrefix("0x"))
    }

    @Test("a duplicate name is rejected")
    func duplicate() throws {
        let manager = AccountManager(store: InMemoryAccountStore())
        _ = try manager.create(name: "a")
        #expect(throws: CLIError.self) { _ = try manager.create(name: "a") }
    }

    @Test("an invalid name is rejected")
    func invalidName() {
        let manager = AccountManager(store: InMemoryAccountStore())
        #expect(throws: CLIError.self) { _ = try manager.create(name: "bad name!") }
    }

    @Test("default is set/read, and deleting the default clears it")
    func defaultAndDelete() throws {
        let manager = AccountManager(store: InMemoryAccountStore())
        _ = try manager.create(name: "a")
        try manager.setDefault(name: "a")
        #expect(try manager.defaultName() == "a")
        try manager.delete(name: "a")
        #expect(try manager.defaultName() == nil)
        #expect(try manager.list().accounts.isEmpty)
    }

    @Test("setting a default to an unknown account throws")
    func unknownDefault() {
        let manager = AccountManager(store: InMemoryAccountStore())
        #expect(throws: AccountStoreError.self) { try manager.setDefault(name: "ghost") }
    }
}

@Suite("ClientKeyLoader account path")
struct ClientKeyLoaderAccountTests {
    @Test("a stored account's key yields the Tempo method")
    func accountKey() throws {
        let store = InMemoryAccountStore()
        _ = try AccountManager(store: store).create(name: "a")
        let methods = try ClientKeyLoader.methods(account: "a", store: store, environment: [:])
        #expect(methods.count == 1)
    }

    @Test("--account with no store on this platform is unsupported")
    func noStore() {
        #expect(throws: CLIError.self) {
            _ = try ClientKeyLoader.methods(account: "a", store: nil, environment: [:])
        }
    }

    @Test("an unknown account yields a clear no-such-account error")
    func unknownAccount() {
        #expect(throws: AccountStoreError.notFound("ghost")) {
            _ = try ClientKeyLoader.methods(
                account: "ghost", store: InMemoryAccountStore(), environment: [:]
            )
        }
    }

    @Test("sign can use a stored account key")
    func signWithAccount() async throws {
        let store = InMemoryAccountStore()
        _ = try AccountManager(store: store).create(name: "payer")
        let signed = try await signedHeader(
            forChallengeValue: tempoChargeChallengeValue(), environment: [:],
            account: "payer", store: store
        )
        #expect(signed.header.hasPrefix("Payment "))
    }
}

@Suite("account exit codes")
struct AccountExitCodeTests {
    @Test("account errors map to their codes")
    func codes() {
        #expect(CLIOutcome(error: CLIError.accountsUnsupported).exitCode == 2)
        #expect(CLIOutcome(error: CLIError.accountExists("a")).exitCode == 2)
        #expect(CLIOutcome(error: CLIError.invalidAccountName("a")).exitCode == 2)
        #expect(CLIOutcome(error: AccountStoreError.notFound("a")).exitCode == 69)
        #expect(CLIOutcome(error: AccountStoreError.ioFailure("x")).exitCode == 1)
    }
}
