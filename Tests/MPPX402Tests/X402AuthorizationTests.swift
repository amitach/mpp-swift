import Foundation
import MPPCore
import MPPEVM
import MPPX402
import Testing

// The EIP-3009 TransferWithAuthorization instrument the x402 "exact" EVM scheme carries. The type
// hash is pinned to the canonical constant the token contract hardcodes (an independent
// correctness anchor); the sign -> recover round-trip and the tamper-rejection cases prove the
// digest is bound to every field and the domain. The authoritative on-chain proof (a real settled
// USDC transfer on Base) lands with the live e2e in a later PR.
@Suite("X402 EIP-3009 authorization")
struct X402AuthorizationTests {
    // Well-known test key 0x..01 and its address, shared with the Tempo tests.
    private static let payerKey = Data(repeating: 0, count: 31) + Data([0x01])
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let usdcBaseHex = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

    private func signer() throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Self.payerKey)
    }

    private func payer() throws -> EthereumAddress {
        try #require(EthereumAddress(uncompressedPublicKey: signer().publicKey))
    }

    /// The real USDC-on-Base domain (name/version/chainId/asset) -- the values a Base resource
    /// server advertises in its x402 PaymentRequirements `extra`.
    private func domain(chainId: UInt64 = 8453) throws -> X402Domain {
        let asset = try #require(EthereumAddress(hex: Self.usdcBaseHex))
        return X402Domain(name: "USDC", version: "2", chainId: chainId, asset: asset)
    }

    private func authorization(
        value: String = "1000000",
        validAfter: UInt64 = 0,
        validBefore: UInt64 = 1_893_456_000,
        nonce: Data = Data(repeating: 0xAB, count: 32),
        recipient: String = recipientHex
    ) throws -> X402Authorization {
        let payee = try #require(EthereumAddress(hex: recipient))
        return try #require(X402Authorization(
            from: payer(),
            recipient: payee,
            value: Amount(value),
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce
        ))
    }

    @Test("the type hash equals the canonical EIP-3009 constant")
    func canonicalTypeHash() {
        // The exact value the EIP-3009 token contracts hardcode as
        // TRANSFER_WITH_AUTHORIZATION_TYPEHASH -- an independent anchor for the type string.
        #expect(
            X402Authorization.transferWithAuthorizationTypeHash.hexPrefixed
                == "0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267"
        )
    }

    @Test("a signature round-trips: the payer signs, the payer is recovered")
    func signRecoverRoundTrip() throws {
        let domain = try domain()
        let auth = try authorization()
        let signature = try auth.sign(domain: domain, with: signer())
        #expect(signature.count == 65) // r ‖ s ‖ v
        #expect(try auth.recoverSigner(domain: domain, signature: signature) == payer())
        #expect(auth.isSignedByFrom(domain: domain, signature: signature))
    }

    @Test("recovery is bound to every field and to the domain")
    func tamperRejected() throws {
        let usdc = try domain()
        let auth = try authorization()
        let signature = try auth.sign(domain: usdc, with: signer())

        // A different value / recipient / nonce / expiry is a different message.
        let wrongValue = try authorization(value: "999")
        let wrongRecipient =
            try authorization(recipient: "0x2222222222222222222222222222222222222222")
        let wrongNonce = try authorization(nonce: Data(repeating: 0xCD, count: 32))
        let wrongExpiry = try authorization(validBefore: 1_893_456_001)
        #expect(!wrongValue.isSignedByFrom(domain: usdc, signature: signature))
        #expect(!wrongRecipient.isSignedByFrom(domain: usdc, signature: signature))
        #expect(!wrongNonce.isSignedByFrom(domain: usdc, signature: signature))
        #expect(!wrongExpiry.isSignedByFrom(domain: usdc, signature: signature))

        // The same authorization under a different domain (chain) is not signed by `from`.
        let otherChain = try domain(chainId: 84532)
        #expect(!auth.isSignedByFrom(domain: otherChain, signature: signature))
    }

    @Test("the nonce must be exactly 32 bytes")
    func nonceWidth() throws {
        let payer = try payer()
        let payee = try #require(EthereumAddress(hex: Self.recipientHex))
        let value = try Amount("1")
        #expect(X402Authorization(
            from: payer, recipient: payee, value: value, validAfter: 0, validBefore: 1,
            nonce: Data(repeating: 0, count: 31)
        ) == nil)
        #expect(X402Authorization(
            from: payer, recipient: payee, value: value, validAfter: 0, validBefore: 1,
            nonce: Data(repeating: 0, count: 33)
        ) == nil)
        #expect(try authorization(nonce: Data(repeating: 0, count: 32)).nonce.count == 32)
    }

    @Test("a value beyond uint256 is unencodable")
    func valueOverflow() throws {
        // 2^256 -- one past the uint256 max.
        let overflow =
            "115792089237316195423570985008687907853269984665640564039457584007913129639936"
        let domain = try domain()
        let auth = try authorization(value: overflow)
        #expect(auth.signingHash(domain: domain) == nil)
        #expect(throws: X402Authorization.SigningError.unencodableValue) {
            _ = try auth.sign(domain: domain, with: signer())
        }
    }

    @Test("the signing hash is stable (regression) and nonce-sensitive")
    func signingHashStable() throws {
        let domain = try domain()
        let hash = try #require(authorization().signingHash(domain: domain))
        #expect(hash.count == 32)
        #expect(hash.hexPrefixed == Self.pinnedSigningHash)
        // A different nonce yields a different digest.
        let other = try #require(
            authorization(nonce: Data(repeating: 0xCD, count: 32)).signingHash(domain: domain)
        )
        #expect(other != hash)
    }

    // Pinned from this implementation for the example USDC/v2/chain-8453 domain above; the type
    // hash is independently anchored to the canonical EIP-3009 constant (see `canonicalTypeHash`),
    // and the live Base settlement e2e (later PR) is the on-chain authority. Changing this without
    // a matching reason is a red flag.
    private static let pinnedSigningHash =
        "0xcdde7f61b76db7e989312e181dd5e8463e7c760c1e34f62155be559790455863"
}
