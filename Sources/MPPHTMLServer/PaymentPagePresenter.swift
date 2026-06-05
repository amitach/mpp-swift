import Foundation
import HTTPTypes
import MPPCore
import MPPHTML
import MPPServer

/// A ``ChallengePresenter`` that renders the `402` as a server-rendered HTML
/// payment page (``MPPHTML``) when the client sends `Accept: text/html`, and
/// otherwise declines so the middleware sends the default
/// `application/problem+json`.
///
/// Wire it into ``MPPServerMiddleware`` via its `presenter` parameter, and route
/// the worker registration fetch (``MPPHTMLServiceWorker/isRequest(_:)``) to
/// ``MPPHTMLServiceWorker/response()`` ahead of the middleware. Together they
/// give a browser a complete pay-in-page flow; a non-browser client (no
/// `text/html`) is unaffected and still gets the problem document.
public struct PaymentPagePresenter: ChallengePresenter {
    private let formatAmount: @Sendable (Challenge) async -> String
    private let methodContent: @Sendable (Challenge) -> PaymentMethodContent
    private let config: PaymentPageConfig
    private let injectsClientBootstrap: Bool

    /// - Parameters:
    ///   - formatAmount: Produces the human-readable amount shown on the page
    ///     from the challenge (e.g. by decoding its `request`). May be async (a
    ///     rate lookup). The renderer sanitizes the returned string.
    ///   - methodContent: The payment method's HTML contribution for a challenge
    ///     (its `<script>` fragment, embedded config, and label).
    ///   - config: Page text and theme. Defaults to the neutral theme.
    ///   - injectsClientBootstrap: When `true` (default), the page embeds the
    ///     ``PaymentPageClientScript`` bootstrap ahead of the method content, so a
    ///     method script can call `window.__mppx.submit(credential)` to drive the
    ///     ``MPPHTMLServiceWorker`` flow. Set `false` if the method content
    ///     handles credential submission itself.
    public init(
        formatAmount: @escaping @Sendable (Challenge) async -> String,
        methodContent: @escaping @Sendable (Challenge) -> PaymentMethodContent,
        config: PaymentPageConfig = PaymentPageConfig(),
        injectsClientBootstrap: Bool = true
    ) {
        self.formatAmount = formatAmount
        self.methodContent = methodContent
        self.config = config
        self.injectsClientBootstrap = injectsClientBootstrap
    }

    public func present(
        _ request: HTTPRequest,
        challenge: Challenge,
        problem _: ProblemDetails
    ) async -> PresentedChallenge? {
        guard acceptsHTML(request) else { return nil }
        let amount = await formatAmount(challenge)
        let method = composed(methodContent(challenge))
        let html = PaymentPage.render(
            challenge: challenge, formattedAmount: amount, method: method, config: config
        )
        return PresentedChallenge(contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    /// The method content, with the client bootstrap prepended when enabled so
    /// `window.__mppx.submit` is defined before the method script runs.
    private func composed(_ base: PaymentMethodContent) -> PaymentMethodContent {
        guard injectsClientBootstrap else { return base }
        return PaymentMethodContent(
            content: PaymentPageClientScript.scriptTag + "\n" + base.content,
            config: base.config,
            label: base.label
        )
    }

    /// Whether the client's `Accept` header offers `text/html`, matching the peer
    /// (a substring check, tolerant of a full `text/html,application/...` list).
    private func acceptsHTML(_ request: HTTPRequest) -> Bool {
        request.headerFields[.accept]?.contains("text/html") ?? false
    }
}
