// Reverse conformance: the reference mppx (TypeScript) CLIENT pays OUR Swift
// server (MPPConformanceServer, backed by TempoProofVerifier) over real HTTP. A
// PASS means a FOREIGN client's zero-amount proof verified against our code.
//
// Dev-only harness. Run via run.sh --reverse (which boots the Swift server first).

import { Mppx, tempo } from 'mppx/client'
import { privateKeyToAccount } from 'viem/accounts'

// Fixed key for determinism; any wallet can prove control of itself.
const account = privateKeyToAccount('0x' + '00'.repeat(31) + '03')
const url = process.env.SERVER_URL ?? 'http://127.0.0.1:8799/proof'

const mppx = Mppx.create({ methods: [tempo({ account })] })

// mppx.fetch transparently handles the 402: it parses the challenge, signs the
// zero-amount proof, and retries with the Authorization: Payment credential.
const response = await mppx.fetch(url)
const body = await response.json().catch(() => ({}))

if (!response.ok || body.paid !== true) {
  console.error(`reverse conformance FAILED: status=${response.status} body=${JSON.stringify(body)}`)
  process.exit(1)
}
console.log(`reverse conformance PASSED: mppx client proof verified by our server (${url})`)
