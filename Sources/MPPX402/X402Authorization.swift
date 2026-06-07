import Foundation
import MPPCore
import MPPEVM

/// The EIP-712 domain of an EIP-3009 token (e.g. USDC on Base), under which a
/// `TransferWithAuthorization` is signed. x402's "exact" EVM scheme carries `name` and `version` in
/// the resource server's PaymentRequirements (`extra`), so the payer signs over exactly the domain
/// the server advertised; `chainId` comes from the `network` and `asset` is the token's
/// `verifyingContract`. A wrong field yields a signature the token contract will not accept.
public struct X402Domain: Sendable, Hashable {
    /// The token's EIP-712 domain `name` (e.g. `"USDC"`).
    public let name: String
    /// The token's EIP-712 domain `version` (e.g. `"2"`).
    public let version: String
    /// The chain the token lives on (e.g. 8453 Base mainnet, 84532 Base Sepolia).
    public let chainId: UInt64
    /// The token contract address -- the EIP-712 `verifyingContract`.
    public let asset: EthereumAddress

    public init(name: String, version: String, chainId: UInt64, asset: EthereumAddress) {
        self.name = name
        self.version = version
        self.chainId = chainId
        self.asset = asset
    }

    /// The EIP-712 domain separator
    /// `keccak256(EIP712Domain(string name,string version,uint256 chainId,address
    /// verifyingContract))`.
    public var separator: Data {
        EIP712.domainSeparator(
            name: name, version: version, chainId: chainId, verifyingContract: asset
        )
    }
}

/// An EIP-3009 `TransferWithAuthorization`: a gasless, pre-signed instruction authorizing a
/// transfer
/// of `value` of an EIP-3009 token (USDC / EURC) from `from` to `to`, valid only within
/// [`validAfter`, `validBefore`) and settleable at most once (`nonce` is a random 32-byte value the
/// token marks used). This is the payment instrument x402's "exact" EVM scheme carries: the payer
/// signs it (EIP-712) and a facilitator / relayer submits `transferWithAuthorization` on-chain,
/// paying the gas.
///
/// The signing digest is `keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(message))` over the
/// canonical EIP-3009 type; ``transferWithAuthorizationTypeHash`` is pinned to the value the token
/// contract hardcodes, so a digest built here is exactly what the contract recovers against.
public struct X402Authorization: Sendable, Hashable {
    /// The payer -- the account whose signature authorizes the transfer.
    public let from: EthereumAddress
    /// The payee (the EIP-3009 / x402 `to` field).
    public let recipient: EthereumAddress
    /// The transfer amount in the token's base units (USDC has 6 decimals, so `"1000000"` = 1
    /// USDC).
    public let value: Amount
    /// Not valid before this unix-seconds timestamp (`0` = no lower bound).
    public let validAfter: UInt64
    /// Not valid at or after this unix-seconds timestamp -- the authorization expires here.
    public let validBefore: UInt64
    /// The random 32-byte `bytes32` nonce the token marks used on settlement (single-use). Random,
    /// not a sequential counter, so many authorizations can be built concurrently without
    /// collision.
    public let nonce: Data

    /// ``value`` pre-encoded as a 32-byte uint256 word, validated at construction (a function of
    /// ``value``, so it does not change equality).
    private let valueWord: Data

    /// Creates an authorization, validating its on-wire constraints eagerly (like ``Voucher``):
    /// returns `nil` if `nonce` is not exactly 32 bytes (the EIP-3009 `bytes32` width) or `value`
    /// exceeds `2^256 - 1` (not a valid uint256). A constructed instance therefore always has an
    /// encodable digest.
    public init?(
        from: EthereumAddress,
        recipient: EthereumAddress,
        value: Amount,
        validAfter: UInt64,
        validBefore: UInt64,
        nonce: Data
    ) {
        guard nonce.count == 32, let valueWord = EIP712.uint256(decimal: value.rawValue) else {
            return nil
        }
        self.from = from
        self.recipient = recipient
        self.value = value
        self.validAfter = validAfter
        self.validBefore = validBefore
        self.nonce = nonce
        self.valueWord = valueWord
    }

    /// The canonical EIP-3009 `TransferWithAuthorization` type hash, identical to the constant the
    /// token contract hardcodes: `keccak256("TransferWithAuthorization(address from,address to,
    /// uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")` =
    /// `0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267`.
    public static let transferWithAuthorizationTypeHash: Data = Keccak256.hash(Data(
        """
        TransferWithAuthorization(address from,address to,uint256 value,\
        uint256 validAfter,uint256 validBefore,bytes32 nonce)
        """.utf8
    ))

    /// `hashStruct(message)` for this authorization.
    public var structHash: Data {
        EIP712.hashStruct(
            typeHash: Self.transferWithAuthorizationTypeHash,
            fields: [
                from.word,
                recipient.word,
                valueWord,
                EIP712.uint256(validAfter),
                EIP712.uint256(validBefore),
                nonce,
            ]
        )
    }

    /// The 32-byte EIP-712 signing digest under `domain`
    /// (`keccak256(0x1901 ‖ domainSeparator ‖ hashStruct)`).
    public func signingHash(domain: X402Domain) -> Data {
        EIP712.signingHash(domainSeparator: domain.separator, structHash: structHash)
    }

    /// Signs this authorization under `domain`, returning the 65-byte Ethereum-wire signature
    /// (`r ‖ s ‖ v`, v in 27...28) the x402 `payload.signature` carries.
    ///
    /// - Throws: the underlying ``Secp256k1Signer`` signing error (``value`` is validated at
    ///   construction, so there is no unencodable-digest case here).
    public func sign(
        domain: X402Domain,
        with signer: Secp256k1Signer
    ) throws(Secp256k1Signer.SigningError) -> Data {
        try signer.sign(hash: signingHash(domain: domain)).ethereumWire
    }

    /// Recovers the signer of `signature` (65-byte Ethereum wire) over this authorization under
    /// `domain`, or `nil` if the signature is not a well-formed 65-byte `r ‖ s ‖ v` or recovery
    /// fails.
    ///
    /// `malleability` gates non-canonical high-`s` signatures: the default
    /// ``SignatureMalleabilityPolicy/accepted`` recovers any signature; ``/rejectHighS`` returns
    /// `nil` for a high-`s` one (EIP-2), letting a verifier be as strict as the settling contract.
    public func recoverSigner(
        domain: X402Domain, signature: Data,
        malleability: SignatureMalleabilityPolicy = .accepted
    ) -> EthereumAddress? {
        EthereumAddress.recover(
            hash: signingHash(domain: domain), signature: signature, malleability: malleability
        )
    }

    /// Whether `signature` (65-byte Ethereum wire) is a valid signature over this authorization
    /// under `domain` by ``from`` -- the check a verifier runs before settling. `malleability` is
    /// forwarded to ``recoverSigner(domain:signature:malleability:)``.
    public func isSignedByFrom(
        domain: X402Domain, signature: Data,
        malleability: SignatureMalleabilityPolicy = .accepted
    ) -> Bool {
        guard let recovered = recoverSigner(
            domain: domain, signature: signature, malleability: malleability
        ) else { return false }
        return recovered == from
    }
}
