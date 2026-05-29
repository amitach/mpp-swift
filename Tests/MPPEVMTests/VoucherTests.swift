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

// Session voucher, pinned byte-for-byte against viem 2.51.3 (hashDomain /
// hashStruct / hashTypedData / signTypedData). Domain "Tempo Stream Channel" v1
// with the escrow as verifyingContract; Voucher(bytes32 channelId,uint128
// cumulativeAmount). The channelId is supplied as input (its derivation lives in
// the channel-open flow, WS-10); here it is the viem-computed value for these
// fixed inputs. Signer = key=1 (address 0x7E5F...Bdf).
@Suite("Voucher")
struct VoucherTests {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func signer() throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [1]))
    }

    private let chainId: UInt64 = 1
    private let escrow = testAddress("0x5FbDB2315678afecb367f032d93F642f64180aa3")
    private let payer = testAddress("0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
    private let payee = testAddress("0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF")
    private let amount = "1000000"
    private let channelID =
        hexData("2f5fe14977863dd95d0179376a659bbe8f8d26dbf784096cb285b6bc6de8a25d")

    @Test("4-field domain type hash matches viem")
    func domainTypeHash() {
        #expect(hex(EIP712.domainTypeHashWithVerifyingContract)
            == "8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f")
    }

    @Test("domainSeparator, structHash, digest, signature match viem")
    func voucherMatchesViem() throws {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: amount))
        let separator = EIP712.domainSeparator(
            name: "Tempo Stream Channel", version: "1", chainId: chainId, verifyingContract: escrow
        )
        #expect(hex(separator)
            == "28178c7534eea94cefdd91508b61fc4adab946a5290642e51c75750d061d3a91")
        #expect(hex(voucher.structHash)
            == "a0dd480380b243e4f332899517d966776f2f15231ffdca584a4b78688bfa8f3c")
        #expect(hex(voucher.signingHash(escrowContract: escrow, chainId: chainId))
            == "39b0aec4b1f1ff52389a0bdb0d599f4fe03c54272020b372979eacbc1e0fc095")
        let signature = try voucher.sign(escrowContract: escrow, chainId: chainId, with: signer())
        #expect(hex(signature) == "4418a5987f9f1c52e2d6792cbe29d11ef2195506303775be32538c0036e8"
            + "b3bc7c978b6004b7c7e73a9d466baa0410661247467678ff9bcbe021c828fc43bfb11b")
    }

    @Test("verify accepts the signer's own raw signature")
    func verifyRoundTrip() throws {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: amount))
        let signature = try voucher.sign(escrowContract: escrow, chainId: chainId, with: signer())
        #expect(voucher.verify(
            escrowContract: escrow, chainId: chainId, signature: signature, expectedSigner: payer
        ))
    }

    @Test(
        "verify REJECTS a magic-suffixed signature (a voucher signature is canonically magic-free)"
    )
    func verifyRejectsMagicSuffixed() throws {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: amount))
        let signature = try voucher.sign(escrowContract: escrow, chainId: chainId, with: signer())
        let withMagic = signature + Data(repeating: 0x77, count: 32)
        #expect(voucher.verify(
            escrowContract: escrow, chainId: chainId, signature: withMagic, expectedSigner: payer
        ) == false)
    }

    @Test("verify REJECTS a keychain envelope even if it embeds the expected signer")
    func verifyRejectsKeychainEnvelope() throws {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: amount))
        let inner = try voucher.sign(escrowContract: escrow, chainId: chainId, with: signer())
        // 0x03 prefix || payer address (20) || inner secp256k1 signature (86 bytes).
        let envelope = Data([0x03]) + payer.bytes + inner
        #expect(voucher.verify(
            escrowContract: escrow, chainId: chainId, signature: envelope, expectedSigner: payer
        ) == false)
    }

    @Test("verify rejects wrong signer, wrong amount, wrong channel")
    func verifyRejectsMismatches() throws {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: amount))
        let signature = try voucher.sign(escrowContract: escrow, chainId: chainId, with: signer())
        #expect(voucher.verify(
            escrowContract: escrow, chainId: chainId, signature: signature, expectedSigner: payee
        ) == false)
        let otherAmount = try #require(Voucher(channelID: channelID, cumulativeAmount: "999"))
        #expect(otherAmount.verify(
            escrowContract: escrow, chainId: chainId, signature: signature, expectedSigner: payer
        ) == false)
        let otherChannel = try #require(Voucher(
            channelID: Data(repeating: 0xAB, count: 32), cumulativeAmount: amount
        ))
        #expect(otherChannel.verify(
            escrowContract: escrow, chainId: chainId, signature: signature, expectedSigner: payer
        ) == false)
    }

    @Test("verify is bound to the domain: a different chainId or escrow rejects")
    func verifyDomainBinding() throws {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: amount))
        let signature = try voucher.sign(escrowContract: escrow, chainId: chainId, with: signer())
        // Same voucher + signature, verified under a different chainId -> different
        // domain separator -> recovers a different address -> rejected.
        #expect(voucher.verify(
            escrowContract: escrow, chainId: 8453, signature: signature, expectedSigner: payer
        ) == false)
        // Same, under a different escrow (verifyingContract).
        #expect(voucher.verify(
            escrowContract: payee, chainId: chainId, signature: signature, expectedSigner: payer
        ) == false)
    }

    @Test("decimal uint256 encoder: zero, value, overflow, malformed")
    func decimalEncoder() throws {
        #expect(try hex(#require(EIP712.uint256(decimal: "0")))
            == String(repeating: "0", count: 64))
        #expect(try hex(#require(EIP712.uint256(decimal: "1000000")))
            == String(repeating: "0", count: 58) + "0f4240")
        // 2^256 - 1 is the max; 2^256 overflows.
        #expect(try hex(#require(EIP712.uint256(decimal:
            "115792089237316195423570985008687907853269984665640564039457584007913129639935")))
            == String(repeating: "f", count: 64))
        #expect(EIP712.uint256(decimal:
            "115792089237316195423570985008687907853269984665640564039457584007913129639936") ==
            nil)
        #expect(EIP712.uint256(decimal: "") == nil)
        #expect(EIP712.uint256(decimal: "12x4") == nil)
    }

    @Test("Voucher init rejects bad channelId length and out-of-range / malformed amount")
    func initValidation() {
        #expect(Voucher(channelID: Data(repeating: 0, count: 31), cumulativeAmount: "1") == nil)
        #expect(Voucher(channelID: channelID, cumulativeAmount: "notanumber") == nil)
        // 2^128 does not fit a uint128; 2^128 - 1 is the max.
        #expect(Voucher(
            channelID: channelID,
            cumulativeAmount: "340282366920938463463374607431768211456"
        ) == nil)
        #expect(Voucher(
            channelID: channelID,
            cumulativeAmount: "340282366920938463463374607431768211455"
        ) != nil)
    }
}
