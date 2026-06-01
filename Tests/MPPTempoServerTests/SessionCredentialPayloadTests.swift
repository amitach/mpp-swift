import Foundation
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempoServer

// The signature-envelope normalization happens once, at the SessionAction.parse deserialize
// boundary, so verify / stored-highest-voucher / on-chain-settle all see the canonical bytes the
// escrow's `ecrecover` redeems. A magic trailer is stripped; a keychain (or otherwise wrapped)
// signature is rejected by failing to parse.
@Suite("SessionCredentialPayload signature normalization")
struct SessionCredentialPayloadTests {
    private func canonicalSignature() throws -> Data {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: "100"))
        let signature = try voucher.sign(
            escrowContract: escrow, chainId: chainID, with: signer(byte: 1)
        )
        #expect(signature.count == 65)
        return signature
    }

    private func voucherPayload(signature: Data) -> [String: JSONValue] {
        [
            "action": .string("voucher"),
            "channelId": .string(hex(channelID)),
            "cumulativeAmount": .string("100"),
            "signature": .string(hex(signature)),
        ]
    }

    @Test("a canonical voucher signature parses unchanged")
    func parsesCanonical() throws {
        let signature = try canonicalSignature()
        let action = SessionAction.parse(voucherPayload(signature: signature))
        guard case let .voucher(fields) = action else {
            Issue.record("expected a voucher action"); return
        }
        #expect(fields.signature == signature)
    }

    @Test("a magic-suffixed voucher signature is stripped to canonical at the boundary")
    func stripsMagicAtBoundary() throws {
        let signature = try canonicalSignature()
        let withMagic = signature + Data(repeating: 0x77, count: 32)
        let action = SessionAction.parse(voucherPayload(signature: withMagic))
        guard case let .voucher(fields) = action else {
            Issue.record("expected a voucher action"); return
        }
        // Downstream (verify, store, settle relay) sees the bare 65 bytes, not the 97-byte input.
        #expect(fields.signature == signature)
    }

    @Test("a keychain-enveloped voucher signature is rejected (parse fails)")
    func rejectsKeychainAtBoundary() throws {
        let inner = try canonicalSignature()
        let envelope = Data([0x03]) + Data(repeating: 0x11, count: 20) +
            inner // 0x03 || addr || inner
        #expect(SessionAction.parse(voucherPayload(signature: envelope)) == nil)
    }

    @Test("the same normalization applies to the close action's voucher signature")
    func stripsMagicOnClose() throws {
        let signature = try canonicalSignature()
        let withMagic = signature + Data(repeating: 0x77, count: 32)
        var payload = voucherPayload(signature: withMagic)
        payload["action"] = .string("close")
        let action = SessionAction.parse(payload)
        guard case let .close(fields) = action else {
            Issue.record("expected a close action"); return
        }
        #expect(fields.signature == signature)
    }
}
