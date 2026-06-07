import Foundation
import MPPCore
import MPPEVM

/// The EIP-3009 authorization as it appears in the x402 "exact" scheme's `payload.authorization`
/// JSON: addresses and the `nonce` as `0x`-hex, and `value` / `validAfter` / `validBefore` as
/// decimal strings (x402 carries all numerics as strings to avoid JSON number precision loss).
///
/// This is the **version-stable** core of x402 -- the `payload` shape is identical across x402 v1
/// and v2; only the surrounding envelope (PaymentRequirements field names, the `X-PAYMENT` vs
/// `PAYMENT-SIGNATURE` header, the CAIP-2 vs short network string) differs by version, and lands
/// with the bridge. The JSON key for the payee is `to`; the Swift property is `recipient` (the
/// 2-character `to` is not a valid identifier name) mapped via ``CodingKeys``.
public struct X402AuthorizationWire: Codable, Sendable, Hashable {
    /// The payer, `0x`-hex (EIP-55 checksummed on encode; parsed case-insensitively).
    public let from: String
    /// The payee (the x402 / EIP-3009 `to` field), `0x`-hex.
    public let recipient: String
    /// The transfer amount in token base units, a decimal string.
    public let value: String
    /// Not-valid-before, a decimal unix-seconds string.
    public let validAfter: String
    /// Not-valid-at-or-after, a decimal unix-seconds string.
    public let validBefore: String
    /// The 32-byte `bytes32` nonce, `0x`-hex.
    public let nonce: String

    public init(
        from: String,
        recipient: String,
        value: String,
        validAfter: String,
        validBefore: String,
        nonce: String
    ) {
        self.from = from
        self.recipient = recipient
        self.value = value
        self.validAfter = validAfter
        self.validBefore = validBefore
        self.nonce = nonce
    }

    private enum CodingKeys: String, CodingKey {
        case from, value, validAfter, validBefore, nonce
        case recipient = "to"
    }
}

public extension X402Authorization {
    /// The x402 wire form of this authorization (addresses EIP-55 checksummed, numerics as decimal
    /// strings, `nonce` as `0x`-hex).
    var wire: X402AuthorizationWire {
        X402AuthorizationWire(
            from: from.checksummed,
            recipient: recipient.checksummed,
            value: value.rawValue,
            validAfter: String(validAfter),
            validBefore: String(validBefore),
            nonce: nonce.hexPrefixed
        )
    }
}

public extension X402AuthorizationWire {
    /// Parses this wire form back into an ``X402Authorization``, or `nil` if any field is malformed
    /// (a non-address `from`/`to`, a non-canonical `value`, a non-`uint64` window, or a `nonce`
    /// that
    /// is not 32 `0x`-hex bytes). Fail-closed: a malformed authorization yields no instance.
    func decoded() -> X402Authorization? {
        guard let from = EthereumAddress(hex: from),
              let recipient = EthereumAddress(hex: recipient),
              let value = try? Amount(value),
              let validAfter = UInt64(validAfter),
              let validBefore = UInt64(validBefore),
              let nonce = Data(hexPrefixed: nonce)
        else { return nil }
        return X402Authorization(
            from: from, recipient: recipient, value: value,
            validAfter: validAfter, validBefore: validBefore, nonce: nonce
        )
    }
}

/// The x402 "exact" scheme `payload`: a signed EIP-3009 authorization. `signature` is the 65-byte
/// Ethereum-wire signature (`r ‖ s ‖ v`) as `0x`-hex; `authorization` is the message it signs. This
/// is the object carried inside the x402 PaymentPayload's `payload`, and -- for this SDK's MPP rail
/// -- inside the MPP ``Credential`` payload.
public struct X402ExactPayload: Codable, Sendable, Hashable {
    /// The 65-byte EIP-3009 signature, `0x`-hex.
    public let signature: String
    /// The signed authorization.
    public let authorization: X402AuthorizationWire

    public init(signature: String, authorization: X402AuthorizationWire) {
        self.signature = signature
        self.authorization = authorization
    }

    /// Builds the payload from a signed authorization. `signature` is the 65-byte Ethereum-wire
    /// signature from ``X402Authorization/sign(domain:with:)``.
    public init(authorization: X402Authorization, signature: Data) {
        self.init(signature: signature.hexPrefixed, authorization: authorization.wire)
    }

    /// The 65-byte signature bytes, or `nil` if `signature` is not exactly 65 `0x`-hex bytes.
    public var signatureBytes: Data? {
        guard let raw = Data(hexPrefixed: signature), raw.count == 65 else { return nil }
        return raw
    }
}

public extension X402ExactPayload {
    /// This payload as an MPP ``Credential`` payload object: the exact `payload`
    /// (`{signature, authorization}`) flattened with a `type: "exact"` discriminator. The client
    /// method puts this in the credential; the server verifier reverses it with
    /// ``init(credentialPayload:)``. The single shared mapping keeps the two sides from drifting.
    func credentialPayload() -> [String: JSONValue] {
        [
            "type": .string("exact"),
            "signature": .string(signature),
            "authorization": .object([
                "from": .string(authorization.from),
                "to": .string(authorization.recipient),
                "value": .string(authorization.value),
                "validAfter": .string(authorization.validAfter),
                "validBefore": .string(authorization.validBefore),
                "nonce": .string(authorization.nonce),
            ]),
        ]
    }

    /// Parses an MPP ``Credential`` payload object produced by ``credentialPayload()``, or `nil` if
    /// the `type` is not `"exact"` or any field is missing. Fail-closed.
    init?(credentialPayload object: [String: JSONValue]) {
        guard object["type"]?.stringValue == "exact",
              let signature = object["signature"]?.stringValue,
              let auth = object["authorization"]?.objectValue,
              let from = auth["from"]?.stringValue,
              let recipient = auth["to"]?.stringValue,
              let value = auth["value"]?.stringValue,
              let validAfter = auth["validAfter"]?.stringValue,
              let validBefore = auth["validBefore"]?.stringValue,
              let nonce = auth["nonce"]?.stringValue
        else { return nil }
        self.init(
            signature: signature,
            authorization: X402AuthorizationWire(
                from: from, recipient: recipient, value: value,
                validAfter: validAfter, validBefore: validBefore, nonce: nonce
            )
        )
    }
}
