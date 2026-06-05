/// The inline page bootstrap that drives credential submission from the browser.
///
/// Embedded in the payment page (before the method's own script), it exposes
/// `window.__mppx.submit(credential)`: a method script calls it once the user
/// has a `Payment ...` credential string. `submit` registers
/// ``MPPHTMLServiceWorker`` at the page URL with the `?__mppx_worker` query,
/// hands it the credential over a `MessageChannel`, then reloads -- on the
/// reload the worker attaches the `Authorization` header and the navigation
/// settles. Ported from the peer's `serviceWorker.client.ts`.
enum PaymentPageClientScript {
    /// The bootstrap wrapped in a `<script>` element, ready to inject into the
    /// page ahead of the method content.
    static let scriptTag = "<script>\(source)</script>"

    static let source = """
    (function () {
      async function submit(credential) {
        const url = new URL(location.href)
        url.searchParams.set('\(MPPHTMLServiceWorker.queryParam)', '')
        const registration = await navigator.serviceWorker.register(url.pathname + url.search)
        const worker = await new Promise((resolve) => {
          const candidate = registration.installing || registration.waiting || registration.active
          if (candidate && candidate.state === 'activated') return resolve(candidate)
          const target = candidate || registration
          target.addEventListener('statechange', function handler() {
            const active = registration.active
            if (active && active.state === 'activated') {
              target.removeEventListener('statechange', handler)
              resolve(active)
            }
          })
        })
        await new Promise((resolve) => {
          const channel = new MessageChannel()
          channel.port1.onmessage = () => resolve()
          worker.postMessage({ credential }, [channel.port2])
        })
        location.reload()
      }
      window.__mppx = window.__mppx || {}
      window.__mppx.submit = submit
    })()
    """
}
