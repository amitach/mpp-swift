import Foundation
import Testing
@testable import MPPEVM

// did:pkh:eip155 proof source DID: canonical build (EIP-55 checksummed address) and
// parse, matching both reference SDKs (mppx proof.ts, mpp-rs proof.rs), including
// mpp-rs's canonical-form rejection of a leading-zero chain id.
@Suite("ProofSource did:pkh:eip155")
struct ProofSourceTests {
    private let address = EthereumAddress(hex: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")

    @Test("builds a checksummed did:pkh:eip155 source DID")
    func build() throws {
        let wallet = try #require(address)
        #expect(ProofSource.did(address: wallet, chainId: 1)
            == "did:pkh:eip155:1:0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
    }

    @Test("round-trips build -> parse")
    func roundTrip() throws {
        let wallet = try #require(address)
        let did = ProofSource.did(address: wallet, chainId: 8453)
        let parsed = try #require(ProofSource.parse(did))
        #expect(parsed.address == wallet)
        #expect(parsed.chainId == 8453)
    }

    @Test("accepts a literal zero chain id")
    func zeroChainId() throws {
        let parsed = try #require(
            ProofSource.parse("did:pkh:eip155:0:0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
        )
        #expect(parsed.chainId == 0)
    }

    @Test("rejects malformed source DIDs")
    func rejectsMalformed() {
        let addr = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
        #expect(ProofSource.parse("did:pkh:eip155:01:\(addr)") == nil) // leading-zero chainId
        #expect(ProofSource.parse("did:pkh:eip155::\(addr)") == nil) // empty chainId
        #expect(ProofSource.parse("did:pkh:eip155:1:0xZZ") == nil) // bad address
        #expect(ProofSource.parse("did:pkh:eip155:1:\(addr)x") == nil) // trailing junk
        #expect(ProofSource.parse("did:web:eip155:1:\(addr)") == nil) // wrong prefix
        #expect(ProofSource
            .parse("did:pkh:eip155:99999999999999999999999:\(addr)") == nil) // u64 overflow
        #expect(ProofSource.parse("did:pkh:eip155:not-a-number:\(addr)") == nil) // non-numeric
        #expect(ProofSource.parse("did:pkh:eip155:1:extra:\(addr)") == nil) // extra colon mid-DID
        #expect(ProofSource.parse("did:pkh:eip155:\(addr)") == nil) // no chainId segment
    }

    // mppx rejects chain ids above 2^53 (a JavaScript Number.isSafeInteger artifact,
    // not a protocol rule); mpp-rs uses u64. We follow mpp-rs: a chain id within
    // UInt64 parses, so 2^53 is accepted, not rejected.
    @Test("accepts a chain id above 2^53 (u64, unlike mppx's JS-safe-integer cap)")
    func acceptsLargeChainId() throws {
        let parsed = try #require(
            ProofSource
                .parse("did:pkh:eip155:9007199254740992:0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
        )
        #expect(parsed.chainId == 9_007_199_254_740_992)
    }
}
