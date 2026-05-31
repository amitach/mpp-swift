import Foundation
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// FU-3: a separate access key signs vouchers (and is the channel's authorizedSigner) while
// the funding wallet (the did:pkh source) funds the channel. Without an access key, the
// funding signer signs and is the authorizedSigner (the default, covered elsewhere).
@Suite("TempoChannelMethod access key")
struct TempoChannelAccessKeyTests {
    @Test("a configured access key is the authorizedSigner + voucher signer; the wallet funds")
    func accessKeySignsVouchers() async throws {
        let accessSigner = try Secp256k1Signer(privateKey: Fixture.accessKey)
        let accessAddress =
            try #require(EthereumAddress(uncompressedPublicKey: accessSigner.publicKey))
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder, voucherSigner: accessSigner)

        let credential = try await method.buildCredential(for: sessionChallenge(amount: "100"))

        // The payer (did:pkh source) is the funding wallet, distinct from the access key.
        #expect(method.address != accessAddress)
        #expect(credential.source == ProofSource.did(
            address: method.address,
            chainId: Fixture.chainId
        ))
        // The open payload's authorizedSigner is the access key, and the open params carry it.
        #expect(credential.payload["authorizedSigner"] == .string(accessAddress.checksummed))
        #expect(await builder.parameters.first?.authorizedSigner == accessAddress)
        // The voucher recovers to the ACCESS key, not the funding wallet.
        #expect(try voucherVerifies(credential.payload, wallet: accessAddress))
        #expect(try voucherVerifies(credential.payload, wallet: method.address) == false)
        // The channel id reflects the access-key authorizedSigner.
        let expected = try expectedChannelID(
            payeeHex: Fixture.payeeHex, wallet: method.address, authorizedSigner: accessAddress
        )
        #expect(credential.payload["channelId"] == .string(expected.hexPrefixed))
    }
}
