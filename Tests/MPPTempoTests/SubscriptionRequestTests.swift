import Foundation
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

@Suite("SubscriptionRequest decode")
struct SubscriptionRequestTests {
    private let currencyHex = "0x20c0000000000000000000000000000000000001"
    private let recipientHex = "0x1111111111111111111111111111111111111111"
    private let accessKeyHex = "0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c"
    private let expiryEpoch: TimeInterval = 1_893_456_000

    /// An ISO-8601 string for the fixed expiry epoch (so the test never hand-maps date <->
    /// seconds).
    private var expiryISO: String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: expiryEpoch))
    }

    private func challenge(_ request: JSONValue) throws -> Challenge {
        try Challenge(
            id: "s", realm: "https://api.example.com", method: MethodName("tempo"),
            intent: .subscription, request: EncodedJSON(json: request)
        )
    }

    private func request(
        amount: String = "1000000",
        currency: String? = nil,
        recipient: String? = nil,
        periodCount: String = "1",
        periodUnit: String = "week",
        expires: String? = nil,
        methodDetails: JSONValue? = .object([
            "accessKey": .object([
                "accessKeyAddress": .string("0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c"),
                "keyType": .string("secp256k1"),
            ]),
            "chainId": .integer(42431),
        ])
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "amount": .string(amount),
            "currency": .string(currency ?? currencyHex),
            "recipient": .string(recipient ?? recipientHex),
            "periodCount": .string(periodCount),
            "periodUnit": .string(periodUnit),
            "subscriptionExpires": .string(expires ?? expiryISO),
        ]
        if let methodDetails { object["methodDetails"] = methodDetails }
        return .object(object)
    }

    @Test("decodes every field of a well-formed subscription request")
    func decodesValid() throws {
        let parsed = try SubscriptionRequest(challenge: challenge(request()))
        #expect(parsed.amount.rawValue == "1000000")
        #expect(try parsed.currency == #require(EthereumAddress(hex: currencyHex)))
        #expect(try parsed.recipient == #require(EthereumAddress(hex: recipientHex)))
        #expect(parsed.periodSeconds == 604_800)
        #expect(parsed.expirySeconds == UInt64(expiryEpoch))
        #expect(try parsed.accessKey?.address == #require(EthereumAddress(hex: accessKeyHex)))
        #expect(parsed.accessKey?.keyType == .secp256k1)
        #expect(parsed.chainId == 42431)
    }

    @Test("a whole-second expiry with a zero fractional (.000Z) is accepted")
    func acceptsZeroFractionalExpiry() throws {
        // Date.toISOString() and the reference SDK emit a whole second as `...:00.000Z`;
        // it must parse to the same epoch as the plain form (cross-SDK interop).
        let parsed = try SubscriptionRequest(
            challenge: challenge(request(expires: "2030-01-01T00:00:00.000Z"))
        )
        let plain = try SubscriptionRequest(
            challenge: challenge(request(expires: "2030-01-01T00:00:00Z"))
        )
        #expect(parsed.expirySeconds == plain.expirySeconds)
    }

    @Test("period units resolve to their second counts")
    func periodUnits() throws {
        #expect(try SubscriptionRequest(challenge: challenge(request(
            periodCount: "2",
            periodUnit: "day"
        )))
        .periodSeconds == 172_800)
        #expect(try SubscriptionRequest(challenge: challenge(request(periodUnit: "dev_second")))
            .periodSeconds == 1)
    }

    @Test("a request without methodDetails has no access key or chain id")
    func noMethodDetails() throws {
        let parsed = try SubscriptionRequest(challenge: challenge(request(methodDetails: nil)))
        #expect(parsed.accessKey == nil)
        #expect(parsed.chainId == nil)
    }

    @Test("a non-canonical or zero period count is rejected")
    func rejectsBadPeriodCount() throws {
        // "٢" is an Arabic-Indic 2: a Unicode digit the strict ASCII grammar rejects.
        for bad in ["0", "01", "x", "٢"] {
            #expect(throws: SubscriptionRequest.DecodingFailure.invalidPeriod) {
                try SubscriptionRequest(challenge: challenge(request(periodCount: bad)))
            }
        }
    }

    @Test("an unknown period unit and an overflowing period are rejected")
    func rejectsBadPeriod() throws {
        #expect(throws: SubscriptionRequest.DecodingFailure.invalidPeriod) {
            try SubscriptionRequest(challenge: challenge(request(periodUnit: "month")))
        }
        // 10^19 weeks overflows UInt64 seconds.
        #expect(throws: SubscriptionRequest.DecodingFailure.invalidPeriod) {
            try SubscriptionRequest(challenge: challenge(
                request(periodCount: "10000000000000000000", periodUnit: "week")
            ))
        }
    }

    @Test("a malformed address, expiry, or access key is rejected")
    func rejectsMalformedFields() throws {
        #expect(throws: SubscriptionRequest.DecodingFailure.self) {
            try SubscriptionRequest(challenge: challenge(request(currency: "0xnope")))
        }
        #expect(throws: SubscriptionRequest.DecodingFailure.invalidExpiry) {
            try SubscriptionRequest(challenge: challenge(request(expires: "not-a-date")))
        }
        // A fractional-seconds expiry is rejected: the key-auth expiry is whole seconds.
        #expect(throws: SubscriptionRequest.DecodingFailure.invalidExpiry) {
            try SubscriptionRequest(
                challenge: challenge(request(expires: "2030-01-01T00:00:00.5Z"))
            )
        }
        #expect(throws: SubscriptionRequest.DecodingFailure.invalidAccessKey) {
            try SubscriptionRequest(challenge: challenge(request(methodDetails: .object([
                "accessKey": .object([
                    "accessKeyAddress": .string("0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c"),
                    "keyType": .string("ed25519"),
                ]),
            ]))))
        }
    }
}
