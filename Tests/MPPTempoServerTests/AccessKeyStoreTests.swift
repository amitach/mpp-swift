import Foundation
import MPPEVM
import MPPTempoServer
import Testing

// The server-held access-key store: provisions a keypair per lookup key, embeds the address
// in the challenge, and keeps the private key for renewal signing. Hermetic.
@Suite("AccessKeyStore")
struct AccessKeyStoreTests {
    /// A Sendable key generator returning a distinct valid key per call, counting calls.
    private final class CountingGenerator: @unchecked Sendable {
        private let lock = NSLock()
        private var counter: UInt8 = 0
        var calls: Int {
            lock.withLock { Int(counter) }
        }

        func next() -> Data {
            lock.withLock {
                counter += 1
                return Data(repeating: 0, count: 31) + Data([counter])
            }
        }
    }

    @Test("the stored private key derives to the provisioned address")
    func provisionDerivesAddress() async throws {
        let store = InMemoryAccessKeyStore()
        let address = try await store.provision(forLookupKey: "cust-1")
        let key = try #require(await store.privateKey(forLookupKey: "cust-1"))
        let signer = try Secp256k1Signer(privateKey: key)
        #expect(EthereumAddress(uncompressedPublicKey: signer.publicKey) == address)
    }

    @Test("a fixed key generator provisions the matching well-known address")
    func deterministicAddress() async throws {
        // Private key 1 derives the canonical account #1 address.
        let one = Data(repeating: 0, count: 31) + Data([0x01])
        let store = InMemoryAccessKeyStore(keyGenerator: { one })
        let address = try await store.provision(forLookupKey: "k")
        #expect(address == EthereumAddress(hex: "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"))
        #expect(await store.privateKey(forLookupKey: "k") == one)
    }

    @Test("provision is idempotent per lookup key and does not regenerate")
    func idempotent() async throws {
        let generator = CountingGenerator()
        let store = InMemoryAccessKeyStore(keyGenerator: { generator.next() })
        let first = try await store.provision(forLookupKey: "k")
        let second = try await store.provision(forLookupKey: "k")
        #expect(first == second)
        #expect(generator.calls == 1)
    }

    @Test("distinct lookup keys get distinct keys and addresses")
    func distinctKeys() async throws {
        let generator = CountingGenerator()
        let store = InMemoryAccessKeyStore(keyGenerator: { generator.next() })
        let addrA = try await store.provision(forLookupKey: "a")
        let addrB = try await store.provision(forLookupKey: "b")
        #expect(addrA != addrB)
        let keyA = await store.privateKey(forLookupKey: "a")
        let keyB = await store.privateKey(forLookupKey: "b")
        #expect(keyA != keyB)
    }

    @Test("an unprovisioned lookup key has no private key")
    func unknownKeyNil() async {
        let store = InMemoryAccessKeyStore()
        #expect(await store.privateKey(forLookupKey: "nope") == nil)
    }

    @Test("concurrent provisions of one lookup key mint exactly one key")
    func concurrentProvisionMintsOnce() async throws {
        let generator = CountingGenerator()
        let store = InMemoryAccessKeyStore(keyGenerator: { generator.next() })
        let addresses = try await withThrowingTaskGroup(of: EthereumAddress.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { try await store.provision(forLookupKey: "k") }
            }
            var seen: [EthereumAddress] = []
            for try await address in group {
                seen.append(address)
            }
            return seen
        }
        #expect(Set(addresses).count == 1)
        #expect(generator.calls == 1)
    }
}
