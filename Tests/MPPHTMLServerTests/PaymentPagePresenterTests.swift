import Foundation
import HTTPTypes
import MPPCore
import MPPHTML
import MPPHTMLServer
import MPPServer
import Testing

@Suite("PaymentPagePresenter")
struct PaymentPagePresenterTests {
    private let problem = ProblemDetails(title: "Payment Required", status: 402)

    @Test("with Accept: text/html it renders the HTML page (amount, bootstrap, method content)")
    func rendersHTML() async throws {
        let presented = try #require(await makePresenter().present(
            makeRequest(accept: "text/html"), challenge: makeChallenge(), problem: problem
        ))
        #expect(presented.contentType == "text/html; charset=utf-8")
        let html = try #require(String(data: presented.body, encoding: .utf8))
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("1.50 USDC"))
        #expect(html.contains("window.__mppx.submit")) // bootstrap injected
        #expect(html.contains("<script>pay()</script>")) // method content
    }

    @Test("the bootstrap is injected ahead of the method content")
    func bootstrapBeforeContent() async throws {
        let presented = try #require(await makePresenter().present(
            makeRequest(accept: "text/html"), challenge: makeChallenge(), problem: problem
        ))
        let html = try #require(String(data: presented.body, encoding: .utf8))
        let bootstrap = try #require(html.range(of: "window.__mppx.submit"))
        let content = try #require(html.range(of: "pay()"))
        #expect(bootstrap.lowerBound < content.lowerBound)
    }

    @Test("a full Accept list containing text/html is honored")
    func acceptList() async throws {
        let presented = try await makePresenter().present(
            makeRequest(accept: "text/html,application/xhtml+xml,*/*;q=0.8"),
            challenge: makeChallenge(),
            problem: problem
        )
        #expect(presented != nil)
    }

    @Test("without text/html the presenter declines (default problem document)")
    func declinesNonHTML() async throws {
        let challenge = try makeChallenge()
        #expect(await makePresenter().present(
            makeRequest(accept: "application/json"), challenge: challenge, problem: problem
        ) == nil)
        #expect(await makePresenter().present(
            makeRequest(accept: nil), challenge: challenge, problem: problem
        ) == nil)
    }

    @Test("injectsClientBootstrap: false omits the bootstrap")
    func bootstrapDisabled() async throws {
        let presenter = makePresenter(injectsClientBootstrap: false)
        let presented = try #require(await presenter.present(
            makeRequest(accept: "text/html"), challenge: makeChallenge(), problem: problem
        ))
        let html = try #require(String(data: presented.body, encoding: .utf8))
        #expect(!html.contains("window.__mppx"))
        #expect(html.contains("<script>pay()</script>"))
    }
}

@Suite("PaymentPagePresenter via MPPServerMiddleware")
struct PaymentPagePresenterIntegrationTests {
    @Test("a browser 402 (Accept: text/html) is served as the HTML page with the retry challenge")
    func browserGets402HTML() async throws {
        let middleware = try makeMiddleware(presenter: makePresenter())
        let (response, body) = await middleware.handle(
            makeRequest(accept: "text/html"), body: Data(), now: now
        ) { _, _ in (HTTPResponse(status: .ok), Data()) }
        #expect(response.status.code == 402)
        #expect(response.headerFields[.contentType] == "text/html; charset=utf-8")
        #expect(response.headerFields[.wwwAuthenticate] != nil) // retry challenge still offered
        #expect(response.headerFields[.cacheControl] == "no-store")
        let html = try #require(String(data: body, encoding: .utf8))
        #expect(html.contains("1.50 USDC"))
    }

    @Test("a non-browser 402 keeps the default application/problem+json")
    func apiGets402Problem() async throws {
        let middleware = try makeMiddleware(presenter: makePresenter())
        let (response, _) = await middleware.handle(
            makeRequest(accept: "application/json"), body: Data(), now: now
        ) { _, _ in (HTTPResponse(status: .ok), Data()) }
        #expect(response.status.code == 402)
        #expect(response.headerFields[.contentType] == "application/problem+json")
    }
}
