import Foundation
import MPPCore
import MPPX402
import Testing

// The version-aware bridge wire: X402Network (CAIP-2 <-> short-name) and X402PaymentRequirements,
// which differ between x402 v1 (maxAmountRequired + short network) and v2 (amount + CAIP-2). Round
// trips per version and the cross-version diff lock the translation.
@Suite("X402 bridge wire")
struct X402BridgeWireTests {
    private static let usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    private static let payTo = "0x1111111111111111111111111111111111111111"

    private func requirements() throws -> X402PaymentRequirements {
        try X402PaymentRequirements(
            network: .baseSepolia, amount: Amount("1000000"), asset: Self.usdc, payTo: Self.payTo,
            maxTimeoutSeconds: 300,
            extra: [
                "name": .string("USD Coin"), "version": .string("2"),
                "assetTransferMethod": .string("eip3009"),
            ]
        )
    }

    // MARK: X402Network

    @Test("network writes CAIP-2 for v2 and a short name for v1")
    func networkWireForms() {
        let base = X402Network.baseSepolia
        #expect(base.caip2 == "eip155:84532")
        #expect(base.shortName == "base-sepolia")
        #expect(base.wireValue(for: .v2) == "eip155:84532")
        #expect(base.wireValue(for: .v1) == "base-sepolia")
        // A chain with no registered short name falls back to CAIP-2 even for v1.
        let obscure = X402Network(chainId: 1)
        #expect(obscure.shortName == nil)
        #expect(obscure.wireValue(for: .v1) == "eip155:1")
    }

    @Test("network parses both CAIP-2 and short names; rejects garbage")
    func networkParse() {
        #expect(X402Network(wire: "eip155:84532") == .baseSepolia)
        #expect(X402Network(wire: "base") == .base)
        #expect(X402Network(wire: "base-sepolia") == .baseSepolia)
        #expect(X402Network(wire: "eip155:1")?.chainId == 1)
        #expect(X402Network(wire: "bogus") == nil)
        #expect(X402Network(wire: "eip155:notanumber") == nil)
    }

    // MARK: X402PaymentRequirements

    @Test("v1 requirements round-trip and use maxAmountRequired + the short network name")
    func roundTripV1() throws {
        let requirements = try requirements()
        let json = requirements.json(for: .v1)
        let object = try #require(json.objectValue)
        #expect(object["maxAmountRequired"]?.stringValue == "1000000")
        #expect(object["amount"] == nil)
        #expect(object["network"]?.stringValue == "base-sepolia")
        #expect(try X402PaymentRequirements(json: json, version: .v1) == requirements)
    }

    @Test("v2 requirements round-trip and use amount + CAIP-2 network")
    func roundTripV2() throws {
        let requirements = try requirements()
        let json = requirements.json(for: .v2)
        let object = try #require(json.objectValue)
        #expect(object["amount"]?.stringValue == "1000000")
        #expect(object["maxAmountRequired"] == nil)
        #expect(object["network"]?.stringValue == "eip155:84532")
        #expect(try X402PaymentRequirements(json: json, version: .v2) == requirements)
    }

    @Test("the same requirements encode differently per version")
    func crossVersionDiffers() throws {
        let requirements = try requirements()
        #expect(requirements.json(for: .v1) != requirements.json(for: .v2))
    }

    @Test("the EIP-712 domain name and version are read from extra")
    func extraAccessors() throws {
        let requirements = try requirements()
        #expect(requirements.assetName == "USD Coin")
        #expect(requirements.assetVersion == "2")
    }

    @Test("decoding fails closed on a missing field, wrong amount key, or negative timeout")
    func failClosed() throws {
        let v2json = try requirements().json(for: .v2)
        // Decoding v2 bytes as v1 misses `maxAmountRequired` -> nil.
        #expect(X402PaymentRequirements(json: v2json, version: .v1) == nil)
        var object = try #require(v2json.objectValue)
        // A missing payTo -> nil.
        var missingPayTo = object
        missingPayTo["payTo"] = nil
        #expect(X402PaymentRequirements(json: .object(missingPayTo), version: .v2) == nil)
        // A negative maxTimeoutSeconds -> nil.
        object["maxTimeoutSeconds"] = .integer(-1)
        #expect(X402PaymentRequirements(json: .object(object), version: .v2) == nil)
    }

    @Test("a present-but-non-object extra fails closed; an absent extra defaults to empty")
    func malformedExtraRejected() throws {
        var object = try #require(requirements().json(for: .v2).objectValue)
        // Absent extra -> empty (still decodes).
        object["extra"] = nil
        #expect(X402PaymentRequirements(json: .object(object), version: .v2)?.extra.isEmpty == true)
        // Present but an array, not an object -> nil.
        object["extra"] = .array([.string("nope")])
        #expect(X402PaymentRequirements(json: .object(object), version: .v2) == nil)
    }

    @Test("a UInt64 timeout beyond Int64.max clamps on encode instead of trapping")
    func largeTimeoutClamps() throws {
        let requirements = try X402PaymentRequirements(
            network: .baseSepolia, amount: Amount("1"), asset: Self.usdc, payTo: Self.payTo,
            maxTimeoutSeconds: .max
        )
        let object = try #require(requirements.json(for: .v2).objectValue)
        #expect(object["maxTimeoutSeconds"]?.integerValue == Int64.max) // clamped, no trap
    }
}
