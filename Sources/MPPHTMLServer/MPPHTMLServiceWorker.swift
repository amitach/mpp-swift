import Foundation
import HTTPTypes

/// The browser service worker that completes the HTML payment flow, plus the
/// server-side helpers to detect and answer its registration request.
///
/// Flow: the payment page's inline bootstrap (``PaymentPageClientScript``)
/// registers this worker at the page URL with a `?__mppx_worker` query, posts it
/// the credential, and reloads. On the reload the worker intercepts the
/// same-origin navigation, sets the `Authorization` header from the stored
/// credential, then unregisters -- so the credential never rides in a URL or a
/// form field, and the retried navigation is an ordinary authorized request the
/// middleware verifies. Ported verbatim from the `mppx` peer for interop.
public enum MPPHTMLServiceWorker {
    /// The query parameter (no value needed) that marks a request as the worker
    /// registration fetch. Matches the peer so a page and worker interoperate
    /// across implementations. A host routes such requests to ``response()``.
    public static let queryParam = "__mppx_worker"

    /// Whether `request` is the worker registration fetch (its path carries the
    /// ``queryParam``). A host checks this before the payment middleware and, when
    /// true, answers with ``response()`` instead.
    public static func isRequest(_ request: HTTPRequest) -> Bool {
        guard let path = request.path,
              let components = URLComponents(string: path)
        else { return false }
        return components.queryItems?.contains { $0.name == queryParam } ?? false
    }

    /// The `200` response serving the worker script (`application/javascript`,
    /// `no-store`).
    public static func response() -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: 200))
        response.headerFields[.contentType] = "application/javascript; charset=utf-8"
        response.headerFields[.cacheControl] = "no-store"
        return (response, Data(script.utf8))
    }

    /// The worker source. Runs in the service-worker global scope.
    static let script = """
    const sw = self
    let credential

    sw.addEventListener('activate', (event) => {
      event.waitUntil(sw.clients.claim())
    })

    sw.addEventListener('message', (event) => {
      if (!event.source) return
      const value = event.data && event.data.credential
      if (typeof value !== 'string' || !value.startsWith('Payment ')) return
      credential = value
      if (event.ports[0]) event.ports[0].postMessage('ack')
    })

    sw.addEventListener('fetch', (event) => {
      if (!credential || event.request.mode !== 'navigate') return
      if (new URL(event.request.url).origin !== sw.location.origin) return

      const headers = new Headers(event.request.headers)
      headers.set('Authorization', credential)
      credential = undefined

      event.respondWith(fetch(event.request, { headers }))
      sw.registration.unregister()
    })
    """
}
