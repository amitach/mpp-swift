import Foundation
import HTTPTypes
import MPPCore
import MPPHTML
import MPPHTMLServer
import MPPServer

let secret = Data("test-secret-key-12345".utf8)
let now = Date(timeIntervalSince1970: 1_767_312_000)

/// A challenge minted for the test route, so the presenter has a realistic value.
func makeChallenge() throws -> Challenge {
    let signer = ChallengeSigner(secret: secret)
    let binding = try RouteBinding(
        realm: "api.example.com",
        method: MethodName("tempo"),
        intent: .charge
    )
    return ChallengeMinter(signer: signer).mint(
        binding: binding,
        request: EncodedJSON("e30"),
        expires: Expires(date: now.addingTimeInterval(3600))
    )
}

/// A middleware wired with `presenter`, minting/verifying for the test route.
func makeMiddleware(presenter: any ChallengePresenter) throws -> MPPServerMiddleware {
    let signer = ChallengeSigner(secret: secret)
    let binding = try RouteBinding(
        realm: "api.example.com",
        method: MethodName("tempo"),
        intent: .charge
    )
    return try MPPServerMiddleware(
        minter: ChallengeMinter(signer: signer),
        verifier: PaymentVerifier(signer: signer, replayStore: InMemoryReplayStore(), methods: []),
        binding: binding,
        request: EncodedJSON("e30"),
        presenter: presenter
    )
}

/// A request carrying an optional `Accept` header (and optional path for the
/// service-worker tests).
func makeRequest(accept: String? = nil, path: String = "/r") -> HTTPRequest {
    var fields = HTTPFields()
    if let accept { fields[.accept] = accept }
    return HTTPRequest(
        method: .post, scheme: "https", authority: "api.example.com", path: path,
        headerFields: fields
    )
}

/// A presenter rendering a fixed amount and method content, for the common case.
func makePresenter(
    amount: String = "1.50 USDC",
    content: String = "<script>pay()</script>",
    injectsClientBootstrap: Bool = true
) -> PaymentPagePresenter {
    PaymentPagePresenter(
        formatAmount: { _ in amount },
        methodContent: { _ in PaymentMethodContent(content: content) },
        injectsClientBootstrap: injectsClientBootstrap
    )
}
