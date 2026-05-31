import Foundation

/// A Tempo **key authorization**: the credential a subscription client signs to delegate recurring
/// payments to a server-held access key.
///
/// A root account signs a `KeyAuthorization` that scopes an access key to a set of token spending
/// limits and call scopes (for a subscription: one recurring `transferWithMemo(currency,
/// recipient)`
/// within a per-period limit, until `expiry`). The signed authorization is the
/// `org.paymentauth/credential` payload for the `tempo`/`subscription` intent.
///
/// The wire format is Tempo's RLP serialization (NOT EIP-712): the inner authorization tuple is
/// `[chainId, type, address, expiry, limits, calls]`; the sign payload is `keccak256` of that
/// tuple's
/// RLP; the serialized credential is the RLP list `[tuple, signature]`. The secp256k1 signature
/// envelope is a bare 65-byte `r ‖ s ‖ v` (`v = recoveryID + 27`), the same form
/// ``Voucher`` and ``EthereumAddress/recover(hash:signature:)`` already use. This type targets the
/// subscription shape (limits + scopes always present); only the secp256k1 key type is signed here.
///
/// Wire format: the Tempo Access Keys specification
/// (<https://docs.tempo.xyz/protocol/transactions/spec-tempo-transaction#access-keys>); the inner
/// tuple is RLP-encoded per Ethereum RLP
/// (<https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/>).
public struct TempoKeyAuthorization: Sendable, Hashable {
    /// The access-key signature scheme. Only ``secp256k1`` is signed/verified by this layer.
    public enum KeyType: Sendable, Hashable {
        case secp256k1
        case p256
        case webAuthn

        /// The RLP tuple byte: empty for secp256k1, `0x01` p256, `0x02` webAuthn.
        var tupleBytes: Data {
            switch self {
            case .secp256k1: Data()
            case .p256: Data([0x01])
            case .webAuthn: Data([0x02])
            }
        }

        init?(tupleBytes: Data) {
            switch [UInt8](tupleBytes) {
            case []: self = .secp256k1
            case [0x01]: self = .p256
            case [0x02]: self = .webAuthn
            default: return nil
            }
        }
    }

    /// A per-token spending limit: up to `limit` base units of `token` per `period` seconds.
    public struct Limit: Sendable, Hashable {
        public var token: EthereumAddress
        /// The per-period cap, a base-units decimal integer string (uint256 range).
        public var limit: String
        /// The period in seconds (0 = a one-time limit, omitted from the tuple).
        public var period: UInt64

        public init(token: EthereumAddress, limit: String, period: UInt64) {
            self.token = token
            self.limit = limit
            self.period = period
        }
    }

    /// A call scope: which `selector` on `address` the access key may call, restricted to
    /// `recipients`.
    public struct Scope: Sendable, Hashable {
        public var address: EthereumAddress
        /// The 4-byte function selector (for a subscription, `transferWithMemo` `0x95777d59`).
        public var selector: Data
        public var recipients: [EthereumAddress]

        public init(address: EthereumAddress, selector: Data, recipients: [EthereumAddress]) {
            self.address = address
            self.selector = selector
            self.recipients = recipients
        }
    }

    /// The access-key address (the "key id").
    public var address: EthereumAddress
    /// The chain id (0 = valid on any chain).
    public var chainID: UInt64
    /// The Unix-seconds expiry.
    public var expiry: UInt64
    public var keyType: KeyType
    public var limits: [Limit]
    public var scopes: [Scope]

    public init(
        address: EthereumAddress,
        chainID: UInt64,
        expiry: UInt64,
        keyType: KeyType = .secp256k1,
        limits: [Limit],
        scopes: [Scope]
    ) {
        self.address = address
        self.chainID = chainID
        self.expiry = expiry
        self.keyType = keyType
        self.limits = limits
        self.scopes = scopes
    }

    /// A reason a key authorization could not be serialized, parsed, or verified.
    public enum AuthorizationError: Error, Sendable, Hashable {
        /// A limit amount was not a valid uint256 decimal integer.
        case invalidAmount(String)
        /// The serialized bytes were not a well-formed key-authorization RLP structure.
        case malformedSerialization
        /// The signature was absent, not a 65-byte secp256k1 envelope, or did not recover.
        case invalidSignature
        /// The local signer failed to sign.
        case signingFailed
    }

    // MARK: - Serialization

    /// The inner authorization tuple `[chainId, type, address, expiry, limits, calls]` as an RLP
    /// item.
    private func authorizationTuple() throws(AuthorizationError) -> RLP.Item {
        var limitItems: [RLP.Item] = []
        for limit in limits {
            guard let amount = EIP712.uint256(decimal: limit.limit) else {
                throw .invalidAmount(limit.limit)
            }
            var fields: [RLP.Item] = [
                .bytes(limit.token.bytes),
                .bytes(Self.stripLeadingZeros(amount)),
            ]
            if limit.period > 0 {
                fields.append(.bytes(Self.minimalBytes(limit.period)))
            }
            limitItems.append(.list(fields))
        }
        return .list([
            .bytes(Self.minimalBytes(chainID)),
            .bytes(keyType.tupleBytes),
            .bytes(address.bytes),
            .bytes(Self.minimalBytes(expiry)),
            .list(limitItems),
            .list(groupedScopeItems()),
        ])
    }

    /// The `calls` value: scopes grouped by target address, preserving first-seen order, each group
    /// `[address, [[selector, [recipients...]], ...]]`.
    private func groupedScopeItems() -> [RLP.Item] {
        var order: [Data] = []
        var rulesByAddress: [Data: [RLP.Item]] = [:]
        for scope in scopes {
            let key = scope.address.bytes
            if rulesByAddress[key] == nil {
                rulesByAddress[key] = []
                order.append(key)
            }
            let recipientItems = scope.recipients.map { RLP.Item.bytes($0.bytes) }
            rulesByAddress[key]?.append(.list([.bytes(scope.selector), .list(recipientItems)]))
        }
        return order.map { key in .list([.bytes(key), .list(rulesByAddress[key] ?? [])]) }
    }

    /// The 32-byte sign payload: `keccak256(RLP(authorizationTuple))` (the tuple only, no
    /// signature).
    public func signPayload() throws(AuthorizationError) -> Data {
        try Keccak256.hash(RLP.encode(authorizationTuple()))
    }

    /// The RLP-serialized authorization: `RLP([tuple])` unsigned, or `RLP([tuple, signature])` when
    /// a
    /// 65-byte secp256k1 `signature` is supplied.
    public func serialize(signature: Data? = nil) throws(AuthorizationError) -> Data {
        let tuple = try authorizationTuple()
        if let signature {
            return RLP.encode(.list([tuple, .bytes(signature)]))
        }
        return RLP.encode(.list([tuple]))
    }

    // MARK: - Signing

    /// Signs the authorization with `signer`, returning the 65-byte secp256k1 envelope `r ‖ s ‖ v`.
    public func sign(with signer: Secp256k1Signer) throws(AuthorizationError) -> Data {
        let payload = try signPayload()
        guard let recoverable = try? signer.sign(hash: payload) else { throw .signingFailed }
        return recoverable.compact + Data([recoverable.recoveryID + 27])
    }

    /// Signs and serializes the authorization into the credential payload's `signature` value.
    public func signedSerialization(with signer: Secp256k1Signer) throws(AuthorizationError)
        -> Data {
        try serialize(signature: sign(with: signer))
    }

    // MARK: - Deserialization + recovery

    /// Parses a serialized authorization into its fields plus the optional 65-byte signature.
    public static func deserialize(
        _ serialized: Data
    ) throws(AuthorizationError) -> (authorization: TempoKeyAuthorization, signature: Data?) {
        guard let outer = try? RLP.decode(serialized),
              case let .list(elements) = outer,
              let first = elements.first,
              case let .list(tuple) = first,
              tuple.count == 6
        else { throw .malformedSerialization }

        let authorization = try parseTuple(tuple)
        let signature: Data?
        switch elements.count {
        case 1: signature = nil
        case 2:
            guard case let .bytes(value) = elements[1] else { throw .malformedSerialization }
            signature = value
        default: throw .malformedSerialization
        }
        return (authorization, signature)
    }

    /// Recovers the signing (payer) address from a signed serialized authorization.
    public static func recover(serialized: Data) throws(AuthorizationError) -> EthereumAddress {
        guard let outer = try? RLP.decode(serialized),
              case let .list(elements) = outer, elements.count == 2,
              case let .bytes(signature) = elements[1], signature.count == 65
        else { throw .invalidSignature }
        // Hash the re-encoded inner tuple: RLP is canonical, so this reproduces the signed payload.
        let payload = Keccak256.hash(RLP.encode(elements[0]))
        guard let signer = EthereumAddress.recover(hash: payload, signature: signature) else {
            throw .invalidSignature
        }
        return signer
    }

    private static func parseTuple(
        _ tuple: [RLP.Item]
    ) throws(AuthorizationError) -> TempoKeyAuthorization {
        guard case let .bytes(chainID) = tuple[0],
              case let .bytes(typeBytes) = tuple[1],
              case let .bytes(addressBytes) = tuple[2],
              case let .bytes(expiry) = tuple[3],
              case let .list(limitItems) = tuple[4],
              case let .list(scopeGroups) = tuple[5],
              let keyType = KeyType(tupleBytes: typeBytes),
              let address = EthereumAddress(bytes: addressBytes)
        else { throw .malformedSerialization }

        var limits: [Limit] = []
        for item in limitItems {
            try limits.append(parseLimit(item))
        }
        var scopes: [Scope] = []
        for group in scopeGroups {
            try scopes.append(contentsOf: parseScopeGroup(group))
        }
        return TempoKeyAuthorization(
            address: address,
            chainID: Self.uint64(chainID),
            expiry: Self.uint64(expiry),
            keyType: keyType,
            limits: limits,
            scopes: scopes
        )
    }

    private static func parseLimit(_ item: RLP.Item) throws(AuthorizationError) -> Limit {
        guard case let .list(fields) = item, fields.count == 2 || fields.count == 3,
              case let .bytes(token) = fields[0], let address = EthereumAddress(bytes: token),
              case let .bytes(amount) = fields[1]
        else { throw .malformedSerialization }
        var period: UInt64 = 0
        if fields.count == 3 {
            guard case let .bytes(periodBytes) = fields[2] else { throw .malformedSerialization }
            period = uint64(periodBytes)
        }
        return Limit(token: address, limit: decimalString(fromBigEndian: amount), period: period)
    }

    private static func parseScopeGroup(_ item: RLP.Item) throws(AuthorizationError) -> [Scope] {
        guard case let .list(group) = item, group.count == 2,
              case let .bytes(addressBytes) = group[0],
              let address = EthereumAddress(bytes: addressBytes),
              case let .list(rules) = group[1]
        else { throw .malformedSerialization }

        var scopes: [Scope] = []
        for rule in rules {
            guard case let .list(parts) = rule, parts.count == 2,
                  case let .bytes(selector) = parts[0],
                  case let .list(recipientItems) = parts[1]
            else { throw .malformedSerialization }
            var recipients: [EthereumAddress] = []
            for element in recipientItems {
                guard case let .bytes(value) = element,
                      let recipient = EthereumAddress(bytes: value)
                else { throw .malformedSerialization }
                recipients.append(recipient)
            }
            scopes.append(Scope(address: address, selector: selector, recipients: recipients))
        }
        return scopes
    }

    // MARK: - Number helpers

    /// The minimal big-endian bytes of a 64-bit value (empty for 0), per RLP's canonical integers.
    private static func minimalBytes(_ value: UInt64) -> Data {
        stripLeadingZeros(EIP712.uint256(value))
    }

    /// Drops leading zero bytes; an all-zero (or empty) input becomes empty `Data`.
    private static func stripLeadingZeros(_ bytes: Data) -> Data {
        Data([UInt8](bytes).drop { $0 == 0 })
    }

    /// A big-endian byte string (<= 8 significant bytes) as a `UInt64`.
    private static func uint64(_ bytes: Data) -> UInt64 {
        [UInt8](bytes).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// A big-endian byte string as a base-10 integer string (the inverse of
    /// ``EIP712/uint256(decimal:)``).
    private static func decimalString(fromBigEndian bytes: Data) -> String {
        var digits: [UInt8] = [0]
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                let value = Int(digits[index]) * 256 + carry
                digits[index] = UInt8(value % 10)
                carry = value / 10
            }
            while carry > 0 {
                digits.append(UInt8(carry % 10))
                carry /= 10
            }
        }
        return String(digits.reversed().map { Character(UnicodeScalar(0x30 + $0)) })
    }
}
