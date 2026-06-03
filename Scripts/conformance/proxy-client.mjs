// Proxy conformance client: the reference mppx SDK pays a route THROUGH our MPPProxy.
//
// `mppx.fetch` transparently handles the 402: it parses the proxy's challenge, signs a zero-amount
// Tempo proof, and retries with `Authorization: Payment`. Our proxy verifies the foreign proof,
// forwards the verified request to its free origin, and relays the origin's body with a
// Payment-Receipt header. Success requires all three: a 2xx, the origin's body relayed, and the
// receipt present (the proxy attached it after a real verification).
import { Mppx, tempo } from 'mppx/client'
import { privateKeyToAccount } from 'viem/accounts'

const account = privateKeyToAccount('0x' + '00'.repeat(31) + '03')
const url = process.env.SERVER_URL ?? 'http://127.0.0.1:8797/proxy/echo/resource'
const verbose = process.env.CONFORMANCE_VERBOSE === '1'

if (verbose) {
  const probe = await fetch(url)
  console.log(`[client] GET ${url} -> ${probe.status}`)
  console.log(`[client]   WWW-Authenticate: ${probe.headers.get('www-authenticate')}`)
}

const mppx = Mppx.create({ methods: [tempo({ account })] })
const response = await mppx.fetch(url)
const body = await response.json().catch(() => ({}))
const receipt = response.headers.get('payment-receipt')

if (verbose) {
  console.log(`[client] paid GET -> ${response.status}`)
  console.log(`[client]   body=${JSON.stringify(body)}`)
  console.log(`[client]   Payment-Receipt=${receipt ? 'present' : 'absent'}`)
}

if (!response.ok || body.origin !== 'hit' || !receipt) {
  console.error(
    `proxy conformance FAILED: status=${response.status} ` +
      `origin=${body.origin} receipt=${receipt ? 'present' : 'absent'}`,
  )
  process.exit(1)
}

console.log(
  'proxy conformance OK: mppx client paid through the proxy, origin body relayed, receipt present',
)
