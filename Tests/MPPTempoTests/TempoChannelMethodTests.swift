import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// TempoChannelMethod is the client side of a tempo/session 402: the first charge to a
// (payee, token, escrow) opens a channel (a signed open tx + an initial voucher), and
// each later charge vouchers against the open channel. These tests are hermetic: a stub
// open-tx builder stands in for the FFI (recording the params it was handed) and the
// salt is fixed, so the channel id and the voucher signature are byte-checkable, and the
// emitted payloads are asserted to match exactly what the server's SessionMethod parses.
@Suite("TempoChannelMethod")
struct TempoChannelMethodTests {
    // MARK: supports() matrix

    @Test("supports a tempo/session challenge naming escrow, recipient, and currency")
    func supportsSession() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        #expect(try method.supports(sessionChallenge()))
    }

    @Test("does not support a tempo/charge challenge (that is the proof method's job)")
    func rejectsChargeIntent() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        #expect(try method.supports(sessionChallenge(intent: "charge")) == false)
    }

    @Test("does not support a different method, or a missing escrow/recipient/currency")
    func rejectsWrongMethodOrMissingFields() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        #expect(try method.supports(sessionChallenge(method: "stripe")) == false)
        #expect(try method.supports(sessionChallenge(escrow: nil)) == false)
        #expect(try method.supports(sessionChallenge(recipient: nil)) == false)
        #expect(try method.supports(sessionChallenge(currency: nil)) == false)
    }

    @Test("does not support a malformed request")
    func rejectsMalformed() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        let challenge = try sessionChallenge(requestOverride: EncodedJSON("@@@not-base64@@@"))
        #expect(method.supports(challenge) == false)
    }

    @Test("advertises the tempo/session range, formatting to a header value")
    func advertises() throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        #expect(AcceptPayment.format(method.paymentRanges) == "tempo/session")
    }

    // MARK: open (first charge)

    @Test("the first charge opens: payload, channel id, deposit, and a verifying voucher")
    func firstChargeOpens() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder)
        let credential = try await method.buildCredential(for: sessionChallenge(amount: "100"))

        #expect(credential.payload["action"] == .string("open"))
        #expect(credential.payload["type"] == .string("transaction"))
        #expect(credential.payload["cumulativeAmount"] == .string("100"))
        #expect(credential.payload["transaction"] == .string(Fixture.txBytes.hexPrefixed))
        #expect(credential.payload["authorizedSigner"] == .string(method.address.checksummed))
        #expect(credential.source == ProofSource.did(
            address: method.address,
            chainId: Fixture.chainId
        ))

        let expectedID = try expectedChannelID(payeeHex: Fixture.payeeHex, wallet: method.address)
        #expect(credential.payload["channelId"] == .string(expectedID.hexPrefixed))

        // The voucher recovers to the wallet (byte-real, not merely well-formed).
        #expect(try voucherVerifies(credential.payload, wallet: method.address))

        // The deposit comes from the policy, never the charge amount; the builder ran once.
        let calls = await builder.parameters
        #expect(calls.count == 1)
        #expect(calls.first?.deposit == Fixture.deposit)
        #expect(calls.first?.deposit != "100")
    }

    @Test("the deposit policy sees the suggestedDeposit and its result is used")
    func depositPolicyUsesSuggested() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(
            depositPolicy: { context in context.suggestedDeposit }, builder: builder
        )
        _ = try await method.buildCredential(for: sessionChallenge(suggestedDeposit: "5000"))
        let calls = await builder.parameters
        #expect(calls.first?.deposit == "5000")
    }

    @Test("a nil deposit policy result rejects the open with noDeposit")
    func noDepositRejectsOpen() async throws {
        let method = try makeMethod(depositPolicy: { _ in nil }, builder: StubOpenTxBuilder())
        await #expect(throws: TempoChannelMethodError.noDeposit) {
            _ = try await method.buildCredential(for: sessionChallenge())
        }
    }

    @Test("a failing open builder surfaces openTransactionFailed")
    func openBuilderFailureSurfaces() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder(failure: StubError.boom))
        await #expect(throws: TempoChannelMethodError.self) {
            _ = try await method.buildCredential(for: sessionChallenge())
        }
    }

    // MARK: voucher (subsequent charges)

    @Test("a second charge to the same recipient vouchers, accumulating, without re-opening")
    func secondChargeVouchers() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder)
        let first = try await method.buildCredential(for: sessionChallenge(amount: "100"))
        let second = try await method.buildCredential(for: sessionChallenge(amount: "200"))

        #expect(second.payload["action"] == .string("voucher"))
        #expect(second.payload["cumulativeAmount"] == .string("300"))
        #expect(second.payload["transaction"] == nil)
        // A voucher action carries no transaction tag (parity: only open/topUp are typed).
        #expect(second.payload["type"] == nil)
        // Same channel as the open, and the cumulative voucher still verifies.
        #expect(second.payload["channelId"] == first.payload["channelId"])
        #expect(try voucherVerifies(second.payload, wallet: method.address))
        #expect(await builder.parameters.count == 1)
    }

    @Test("a charge to a different recipient opens a second, distinct channel")
    func differentRecipientOpensAgain() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder)
        let first = try await method
            .buildCredential(for: sessionChallenge(recipient: Fixture.payeeHex))
        let second = try await method
            .buildCredential(for: sessionChallenge(recipient: Fixture.payee2Hex))

        #expect(first.payload["action"] == .string("open"))
        #expect(second.payload["action"] == .string("open"))
        #expect(first.payload["channelId"] != second.payload["channelId"])
        #expect(await builder.parameters.count == 2)
    }

    // MARK: amount + cumulative edges

    @Test("an amount that does not fit uint128 throws amountExceedsChannelRange")
    func amountTooLarge() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        // 2^128, one past the channel uint128 max.
        let over = "340282366920938463463374607431768211456"
        await #expect(throws: TempoChannelMethodError.amountExceedsChannelRange) {
            _ = try await method.buildCredential(for: sessionChallenge(amount: over))
        }
    }

    @Test("a cumulative that would overflow uint128 throws cumulativeOverflow")
    func cumulativeOverflows() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        let max = "340282366920938463463374607431768211455" // 2^128 - 1
        _ = try await method.buildCredential(for: sessionChallenge(amount: max))
        await #expect(throws: TempoChannelMethodError.cumulativeOverflow) {
            _ = try await method.buildCredential(for: sessionChallenge(amount: "1"))
        }
    }

    // MARK: approval + direct misuse

    @Test("a denying policy produces no credential and does not open")
    func approvalDenied() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(approval: .deny, builder: builder)
        await #expect(throws: TempoChannelMethodError.approvalDenied) {
            _ = try await method.buildCredential(for: sessionChallenge())
        }
        #expect(await builder.parameters.isEmpty)
    }

    @Test("buildCredential refuses a wrong method/intent even when called directly")
    func refusesWrongMethodIntent() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        await #expect(throws: TempoChannelMethodError.wrongMethodOrIntent) {
            _ = try await method.buildCredential(for: sessionChallenge(intent: "charge"))
        }
    }

    // MARK: concurrency

    @Test("concurrent first charges to one key open exactly one channel")
    func concurrentOpensOnce() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(builder: builder)
        let challenge = try sessionChallenge(amount: "10")
        let actions = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 12 {
                group.addTask {
                    let credential = try await method.buildCredential(for: challenge)
                    return try #require(jsonString(credential.payload["action"]))
                }
            }
            var collected: [String] = []
            for try await action in group {
                collected.append(action)
            }
            return collected
        }
        #expect(actions.count(where: { $0 == "open" }) == 1)
        #expect(actions.count(where: { $0 == "voucher" }) == 11)
        #expect(await builder.parameters.count == 1)
    }

    @Test("concurrent charges all throw (and do not hang) when every open fails")
    func concurrentFailingOpensDoNotHang() async throws {
        // The failed-open slot is cleared inside the open task, so waiters never busy-wait
        // on a completed-but-failed task: each charge surfaces its own error and returns.
        let method = try makeMethod(builder: StubOpenTxBuilder(failure: StubError.boom))
        let challenge = try sessionChallenge(amount: "10")
        let thrown = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    do {
                        _ = try await method.buildCredential(for: challenge)
                        return false
                    } catch {
                        return true
                    }
                }
            }
            var count = 0
            for await didThrow in group where didThrow {
                count += 1
            }
            return count
        }
        #expect(thrown == 8)
    }

    @Test("DepositContext is publicly constructible for policy unit tests")
    func depositContextPublicInit() throws {
        let payee = try #require(EthereumAddress(hex: Fixture.payeeHex))
        let token = try #require(EthereumAddress(hex: Fixture.tokenHex))
        let escrow = try #require(EthereumAddress(hex: Fixture.escrowHex))
        let context = try DepositContext(
            payee: payee, token: token, escrow: escrow, chainId: 1,
            chargeAmount: Amount("100"), suggestedDeposit: "5000"
        )
        #expect(context.suggestedDeposit == "5000")
    }

    // MARK: end-to-end through PaymentClient

    @Test("end-to-end: a 402 session is paid and the retry carries the open credential")
    func endToEnd() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        let challenge = try sessionChallenge(amount: "100")
        let transport = SessionRecordingTransport(challengeHeader: challenge.headerValue)
        let client = PaymentClient(transport: transport, methods: [method])
        let request = HTTPRequest(
            method: .get, scheme: "https", authority: "api.example.com", path: "/paid"
        )

        let (response, body) = try await client.send(request)
        #expect(response.status.code == 200)
        #expect(body == Data("paid".utf8))

        let sent = await transport.sent
        #expect(sent.count == 2)
        let auth = try #require(sent[1].request.headerFields[.authorization])
        #expect(auth.hasPrefix("Payment "))
        let credential = try Credential(headerValue: auth)
        #expect(credential.payload["action"] == .string("open"))
        #expect(try voucherVerifies(credential.payload, wallet: method.address))
    }
}
