import Foundation
import HTTPTypes
import MPPHTMLServer
import Testing

@Suite("MPPHTMLServiceWorker")
struct MPPHTMLServiceWorkerTests {
    @Test("a path carrying the worker query param is recognized")
    func detectsWorkerRequest() {
        #expect(MPPHTMLServiceWorker.isRequest(makeRequest(path: "/r?__mppx_worker=")))
        #expect(MPPHTMLServiceWorker.isRequest(makeRequest(path: "/r?foo=1&__mppx_worker=")))
    }

    @Test("an ordinary path is not a worker request")
    func ignoresOrdinaryRequest() {
        #expect(!MPPHTMLServiceWorker.isRequest(makeRequest(path: "/r")))
        #expect(!MPPHTMLServiceWorker.isRequest(makeRequest(path: "/r?foo=1")))
    }

    @Test("response serves the worker script as no-store javascript")
    func response() throws {
        let (response, body) = MPPHTMLServiceWorker.response()
        #expect(response.status.code == 200)
        #expect(response.headerFields[.contentType] == "application/javascript; charset=utf-8")
        #expect(response.headerFields[.cacheControl] == "no-store")
        let script = try #require(String(data: body, encoding: .utf8))
        // The worker's defining behavior: it intercepts navigations and injects Authorization.
        #expect(script.contains("addEventListener('fetch'"))
        #expect(script.contains("headers.set('Authorization', credential)"))
        #expect(script.contains("sw.registration.unregister()"))
    }
}
