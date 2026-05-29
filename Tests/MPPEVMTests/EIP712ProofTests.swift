import Foundation
import Testing
@testable import MPPEVM

// EIP-712 zero-amount proof, pinned byte-for-byte against viem 2.51.3
// (hashDomain / hashStruct / hashTypedData / signTypedData), which shares its
// secp256k1 and EIP-712 implementation lineage with the reference SDKs. Both proof
// variants are covered: v2 `Proof(string challengeId,string realm)` (domain
// version "2") and v1 `Proof(string challengeId,address wallet)` (domain version
// "1"). Fixed inputs: private key 0x..01, chainId 1, challengeId "test-challenge".
@Suite("EIP712 zero-amount proof")
struct EIP712ProofTests {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func signer() throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [1]))
    }

    private let chainId: UInt64 = 1
    private let challengeId = "test-challenge"
    private let realm = "https://api.example.com"

    @Test("EIP712Domain type hash matches viem keccak256(encodeType)")
    func domainTypeHash() {
        #expect(hex(EIP712.domainTypeHash)
            == "c2f8787176b8ac6bf7215b4adcc1e069bf4ab82d9ab1df05a57a91d425935b6e")
        // The per-variant Proof type hashes are pinned transitively by the
        // byte-exact structHash assertions in proofV1 / proofV2.
    }

    @Test("Ethereum address derives from the signer public key (key=1 -> 0x7E5F...)")
    func addressDerivation() throws {
        let address = try #require(EthereumAddress(uncompressedPublicKey: signer().publicKey))
        #expect(hex(address.bytes) == "7e5f4552091a69125d5dfcb7b8c2659029395bdf")
        // EIP-55 checksum rendering matches viem's canonical form.
        #expect(address.checksummed == "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
    }

    @Test("v2 (mppx): domainSeparator, structHash, digest, signature match viem")
    func proofV2() throws {
        let proof = ZeroAmountProof.v2Realm(challengeId: challengeId, realm: realm)
        let separator = EIP712.domainSeparator(name: "MPP", version: "2", chainId: chainId)
        #expect(hex(separator)
            == "76e1f45830259ea99a196ff65b62c948cadfbe28194e01f84f19f12ef6200715")
        #expect(hex(proof.structHash)
            == "7c6ee538ed2049cdee89216ea34be343b024b2fe197ae06a69439b2ea47dc307")
        #expect(hex(proof.signingHash(chainId: chainId))
            == "ca1eaea04e8d1821039328da7862d857b1804c33f825f36b2761783af24ebdf4")
        let signature = try proof.sign(chainId: chainId, with: signer())
        #expect(hex(signature) == "499c7c6c221e2d984dedcd9cf8656dd7f2e99ad7a81f9e538606d15f29"
            + "daff057ce1854ee7328b3bc06e4ec952051b534bcf4a4d21c74e9efb5579aa3a20d6be1b")
    }

    @Test("v1 (mpp-rs): domainSeparator, structHash, digest, signature match viem")
    func proofV1() throws {
        let wallet = try EthereumAddress(uncompressedPublicKey: signer().publicKey)
        let unwrapped = try #require(wallet)
        let proof = ZeroAmountProof.v1Wallet(challengeId: challengeId, wallet: unwrapped)
        let separator = EIP712.domainSeparator(name: "MPP", version: "1", chainId: chainId)
        #expect(hex(separator)
            == "985f22fac225b9109d8e02c7b13835bf17df431f2e2e13b883c2db2c675053a2")
        #expect(hex(proof.structHash)
            == "d1e9ba82b34bbc97705abf3884685c522931613a3f1b86ec4367160629e8049c")
        #expect(hex(proof.signingHash(chainId: chainId))
            == "2dc055479c9286742ad31afee28167dea8a507b878bf219b98d0d1ea0dea2886")
        let signature = try proof.sign(chainId: chainId, with: signer())
        #expect(hex(signature) == "7744bdd24959436cace9677f5850168e387eb2a319cbdac69fcf06aff2"
            + "b19ab919fb941c39f18ca8c2b5858659a7b92e51fc0e8bb926d013e427b446e2665f881b")
    }

    @Test("spec single-field (v1 challengeId-only): structHash, digest, signature match viem")
    func proofSpecV1() throws {
        // draft-tempo-charge-00 normative form: domain version "1",
        // Proof(string challengeId). Pinned against viem 2.51.3 signTypedData.
        let proof = ZeroAmountProof.v1ChallengeId(challengeId: challengeId)
        #expect(hex(proof.structHash)
            == "b211262a3ec0d24072c4b153d6d207af2344921e7de4108cb2c82a5652007961")
        #expect(hex(proof.signingHash(chainId: chainId))
            == "e1d9824d50717ea38a8178599a804f27e0d17ca0c0559d843e34fd68c5e46fbf")
        let signature = try proof.sign(chainId: chainId, with: signer())
        #expect(hex(signature) == "864872e5ccf7559d9921b163f5a9e4136c03098e0bbaab656de9993e4e183da0"
            + "0e377b98c77aed27ab86689b6c1a52ba5e53cf7b2838992da8a404e4f6768cf21b")
    }

    @Test("recoverSigner round-trips: the recovered address equals the signer's")
    func recoverRoundTrip() throws {
        let wallet = try #require(EthereumAddress(uncompressedPublicKey: signer().publicKey))
        let proof = ZeroAmountProof.v2Realm(challengeId: challengeId, realm: realm)
        let signature = try proof.sign(chainId: chainId, with: signer())
        #expect(proof.recoverSigner(chainId: chainId, signature: signature) == wallet)
    }

    @Test("recoverSigner against a different challenge recovers a different address")
    func recoverWrongChallenge() throws {
        let wallet = try #require(EthereumAddress(uncompressedPublicKey: signer().publicKey))
        let signed = ZeroAmountProof.v2Realm(challengeId: challengeId, realm: realm)
        let signature = try signed.sign(chainId: chainId, with: signer())
        let other = ZeroAmountProof.v2Realm(challengeId: "different-challenge", realm: realm)
        #expect(other.recoverSigner(chainId: chainId, signature: signature) != wallet)
    }

    @Test("recoverSigner returns nil for a malformed signature")
    func recoverMalformed() {
        let proof = ZeroAmountProof.v2Realm(challengeId: challengeId, realm: realm)
        #expect(proof
            .recoverSigner(chainId: chainId, signature: Data(repeating: 0, count: 64)) == nil)
        // v byte below the 27 offset is not a valid Ethereum recovery id.
        #expect(proof.recoverSigner(
            chainId: chainId, signature: Data(repeating: 0, count: 64) + Data([26])
        ) == nil)
    }

    @Test("the two variants produce different signing hashes (version + field differ)")
    func variantsDiffer() throws {
        let v2Hash = ZeroAmountProof.v2Realm(challengeId: challengeId, realm: realm)
            .signingHash(chainId: chainId)
        let wallet =
            try #require(EthereumAddress(hex: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"))
        let v1Hash = ZeroAmountProof.v1Wallet(challengeId: challengeId, wallet: wallet)
            .signingHash(chainId: chainId)
        #expect(v1Hash != v2Hash)
    }

    @Test("address word is left-padded to 32 bytes; uint256 is big-endian")
    func wordEncoding() throws {
        let wallet =
            try #require(EthereumAddress(hex: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"))
        #expect(wallet.word.count == 32)
        #expect(hex(wallet.word) ==
            "0000000000000000000000007e5f4552091a69125d5dfcb7b8c2659029395bdf")
        #expect(hex(EIP712.uint256(1)) == String(repeating: "0", count: 63) + "1")
        #expect(hex(EIP712.uint256(0)) == String(repeating: "0", count: 64))
    }

    @Test("address parsing rejects malformed input")
    func addressParsing() {
        #expect(EthereumAddress(hex: "7E5F4552091A69125d5DfCb7b8C2659029395Bdf") == nil) // no 0x
        #expect(EthereumAddress(hex: "0x7E5F") == nil) // too short
        #expect(EthereumAddress(hex: "0xZZ5F4552091A69125d5DfCb7b8C2659029395Bdf") ==
            nil) // non-hex
        #expect(EthereumAddress(bytes: Data(repeating: 0, count: 19)) == nil) // wrong length
    }
}
