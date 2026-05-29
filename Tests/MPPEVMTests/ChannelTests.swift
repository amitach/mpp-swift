import Foundation
import Testing
@testable import MPPEVM

private func testAddress(_ hex: String) -> EthereumAddress {
    guard let address = EthereumAddress(hex: hex) else {
        preconditionFailure("invalid test address \(hex)")
    }
    return address
}

private func hexData(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index ..< next], radix: 16) else {
            preconditionFailure("invalid test hex \(hex)")
        }
        data.append(byte)
        index = next
    }
    return data
}

// channelId = keccak256(abi.encode(payer, payee, token, salt, authorizedSigner,
// escrowContract, chainId)), the escrow contract's computeChannelId. The byte-exact
// test pins the ABI encoding by hand-building the 224-byte preimage (seven static
// 32-byte words) and hashing it with Keccak256 (itself pinned to known vectors in
// Keccak256Tests), independent of how Channel.id assembles the words.
@Suite("Channel")
struct ChannelTests {
    // Canonical inputs (shared with the peer SDKs' computeChannelId tests).
    private let payer = testAddress("0x1111111111111111111111111111111111111111")
    private let payee = testAddress("0x2222222222222222222222222222222222222222")
    private let token = testAddress("0x3333333333333333333333333333333333333333")
    private let salt = hexData("0000000000000000000000000000000000000000000000000000000000000001")
    private let authorizedSigner = testAddress("0x4444444444444444444444444444444444444444")
    private let escrow = testAddress("0x5555555555555555555555555555555555555555")
    private let chainId: UInt64 = 42431

    private func id(
        payer: EthereumAddress? = nil,
        payee: EthereumAddress? = nil,
        token: EthereumAddress? = nil,
        salt: Data? = nil,
        authorizedSigner: EthereumAddress? = nil,
        escrow: EthereumAddress? = nil,
        chainId: UInt64? = nil
    ) -> Data? {
        Channel.Parameters(
            payer: payer ?? self.payer,
            payee: payee ?? self.payee,
            token: token ?? self.token,
            salt: salt ?? self.salt,
            authorizedSigner: authorizedSigner ?? self.authorizedSigner,
            escrowContract: escrow ?? self.escrow,
            chainId: chainId ?? self.chainId
        ).map(Channel.id)
    }

    @Test("matches keccak256 of the hand-built ABI-encode preimage")
    func matchesAbiEncodePreimage() throws {
        // Seven 32-byte words: addresses left-padded, salt as bytes32, chainId
        // (42431 = 0xa5bf) as a uint256.
        let preimage = hexData(
            "000000000000000000000000" + "1111111111111111111111111111111111111111"
                + "000000000000000000000000" + "2222222222222222222222222222222222222222"
                + "000000000000000000000000" + "3333333333333333333333333333333333333333"
                + "0000000000000000000000000000000000000000000000000000000000000001"
                + "000000000000000000000000" + "4444444444444444444444444444444444444444"
                + "000000000000000000000000" + "5555555555555555555555555555555555555555"
                + "000000000000000000000000000000000000000000000000000000000000a5bf"
        )
        #expect(preimage.count == 224)
        let derived = try #require(id())
        #expect(derived == Keccak256.hash(preimage))
        #expect(derived.count == 32)
        // Self-contained pinned value for the canonical inputs (computed via this
        // SDK's Keccak256, which is pinned to known-answer vectors in Keccak256Tests).
        // Cross-check against viem/cast computeChannelId when network is available.
        #expect(derived
            == hexData("5db832ef1f06a767e0561f2fe53231240f8804895a21d5804ddb15b329c73c5e"))
    }

    @Test("is deterministic for the same inputs")
    func deterministic() throws {
        #expect(try #require(id()) == #require(id()))
    }

    @Test("changing any single field changes the id (every field is encoded)")
    func everyFieldAffectsTheID() throws {
        let base = try #require(id())
        let other = testAddress("0x9999999999999999999999999999999999999999")
        let otherSalt = hexData("0000000000000000000000000000000000000000000000000000000000000002")
        #expect(try #require(id(payer: other)) != base)
        #expect(try #require(id(payee: other)) != base)
        #expect(try #require(id(token: other)) != base)
        #expect(try #require(id(salt: otherSalt)) != base)
        #expect(try #require(id(authorizedSigner: other)) != base)
        #expect(try #require(id(escrow: other)) != base)
        #expect(try #require(id(chainId: 1)) != base)
    }

    @Test("Parameters rejects a salt that is not exactly 32 bytes", arguments: [0, 31, 33, 64])
    func rejectsNon32ByteSalt(byteCount: Int) {
        #expect(Channel.Parameters(
            payer: payer, payee: payee, token: token,
            salt: Data(repeating: 0, count: byteCount),
            authorizedSigner: authorizedSigner, escrowContract: escrow, chainId: chainId
        ) == nil)
    }

    @Test("a derived channel id binds a valid, verifiable voucher")
    func derivedIDBindsAVoucher() throws {
        // The whole point of the derivation: the 32-byte id is what a Voucher is
        // bound to and signed over. key=1 -> address 0x7E5F...Bdf (per VoucherTests).
        let channelID = try #require(id())
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: "1000000"))
        let signer = try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [1]))
        let signature = try voucher.sign(escrowContract: escrow, chainId: chainId, with: signer)
        #expect(voucher.verify(
            escrowContract: escrow,
            chainId: chainId,
            signature: signature,
            expectedSigner: testAddress("0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
        ))
    }
}
