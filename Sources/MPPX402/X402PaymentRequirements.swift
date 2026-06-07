import Foundation
import MPPCore

/// One x402 payment option a resource server advertises (an entry in a 402's `accepts`): which
/// scheme, on which chain, how much of which token to whom, and a validity window. This is the
/// neutral, version-agnostic value; ``json(for:)`` / ``init(json:version:)`` translate it to and
/// from the x402 v1 and v2 wire shapes, which differ in the amount field name (`maxAmountRequired`
/// vs `amount`) and the `network` encoding (a short name vs CAIP-2).
public struct X402PaymentRequirements: Sendable, Hashable {
    /// The x402 scheme (`exact` for an EIP-3009 transfer).
    public let scheme: String
    /// The chain the token lives on.
    public let network: X402Network
    /// The amount in the token's base units (x402 v1 `maxAmountRequired`, v2 `amount`).
    public let amount: Amount
    /// The token contract address.
    public let asset: String
    /// The payee address.
    public let payTo: String
    /// How long the server will wait for settlement, in seconds.
    public let maxTimeoutSeconds: UInt64
    /// Scheme-specific extra data; for `exact`/EIP-3009 it carries the token's EIP-712 domain
    /// `name` / `version` (and optionally `assetTransferMethod`).
    public let extra: [String: JSONValue]

    public init(
        scheme: String = "exact",
        network: X402Network,
        amount: Amount,
        asset: String,
        payTo: String,
        maxTimeoutSeconds: UInt64,
        extra: [String: JSONValue] = [:]
    ) {
        self.scheme = scheme
        self.network = network
        self.amount = amount
        self.asset = asset
        self.payTo = payTo
        self.maxTimeoutSeconds = maxTimeoutSeconds
        self.extra = extra
    }

    /// The token's EIP-712 domain `name` from `extra`, if present.
    public var assetName: String? {
        extra["name"]?.stringValue
    }

    /// The token's EIP-712 domain `version` from `extra`, if present.
    public var assetVersion: String? {
        extra["version"]?.stringValue
    }

    /// Encodes to the x402 wire JSON for `version`: v1 writes `maxAmountRequired` + a short
    /// `network` name; v2 writes `amount` + CAIP-2.
    public func json(for version: X402Version) -> JSONValue {
        var object: [String: JSONValue] = [
            "scheme": .string(scheme),
            "network": .string(network.wireValue(for: version)),
            "asset": .string(asset),
            "payTo": .string(payTo),
            // `JSONValue.integer` is Int64; clamp (never trap) a UInt64 beyond Int64.max. Such a
            // timeout is nonsensical anyway, and the decode side already rejects a negative value.
            "maxTimeoutSeconds": .integer(Int64(clamping: maxTimeoutSeconds)),
        ]
        object[version == .v1 ? "maxAmountRequired" : "amount"] = .string(amount.rawValue)
        if !extra.isEmpty {
            object["extra"] = .object(extra)
        }
        return .object(object)
    }

    /// Parses x402 wire JSON for `version`, or `nil` if a required field is missing or malformed
    /// (fail-closed).
    public init?(json: JSONValue, version: X402Version) {
        guard case let .object(object) = json,
              let scheme = object["scheme"]?.stringValue,
              let networkWire = object["network"]?.stringValue,
              let network = X402Network(wire: networkWire),
              let asset = object["asset"]?.stringValue,
              let payTo = object["payTo"]?.stringValue,
              let timeoutValue = object["maxTimeoutSeconds"]?.integerValue, timeoutValue >= 0,
              let amountWire = object[version == .v1 ? "maxAmountRequired" : "amount"]?.stringValue,
              let amount = try? Amount(amountWire)
        else { return nil }
        self.init(
            scheme: scheme, network: network, amount: amount, asset: asset, payTo: payTo,
            maxTimeoutSeconds: UInt64(timeoutValue), extra: object["extra"]?.objectValue ?? [:]
        )
    }
}
