// Reference mppx (TypeScript) server for cross-SDK conformance testing.
//
// Boots a minimal HTTP server with a single endpoint that issues a zero-amount
// `tempo`/`charge` 402 challenge and verifies the proof credential the Swift
// client returns. The zero-amount proof is identity-only (EIP-712 ecrecover), so
// no Tempo RPC is contacted on the happy path; `testnet: true` fixes the chainId
// to Moderato (42431) without a network call.
//
// Dev-only harness. Not shipped. Run via `npm run serve` (see run.sh).

import { createServer } from 'node:http'
import { Mppx, tempo } from 'mppx/server'
import { privateKeyToAccount } from 'viem/accounts'

// Fixed key for determinism (the server's recipient identity; not a real fund).
const account = privateKeyToAccount('0x' + '00'.repeat(31) + '02')
// Moderato testnet pathUSD; the currency does not bind into a zero-amount proof.
const currency = '0x20c0000000000000000000000000000000000000'

const mppx = Mppx.create({
  // Fixed challenge-id HMAC secret (>= 32 bytes) for a deterministic harness.
  // This is a test-only secret, not a credential to anything real.
  secretKey: 'mpp-swift-conformance-harness-fixed-secret-key-0123456789',
  methods: [
    tempo({
      account,
      currency,
      recipient: account.address,
      testnet: true,
    }),
  ],
})

const PORT = Number(process.env.PORT ?? 8788)
const MODE = process.env.CONFORMANCE_MODE ?? 'local'
// Moderato testnet (chainId 42431). Used only by the optional `testnet` mode's
// startup reachability probe; the zero-amount proof itself never calls it.
const MODERATO_RPC = 'https://rpc.moderato.tempo.xyz'

/**
 * In `testnet` mode, prove the live Moderato node is reachable (eth_chainId).
 * The proof path is identical to `local` (ecrecover, chainId 42431, no RPC); this
 * probe is the live-chain touch and the seam for the future settled-transfer test.
 */
async function probeModerato() {
  const response = await fetch(MODERATO_RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }),
  })
  const json = await response.json()
  const chainId = Number(json.result)
  if (chainId !== 42431) throw new Error(`unexpected chainId ${chainId} (expected 42431)`)
  console.log(`moderato reachable: eth_chainId=${json.result} (${chainId})`)
}

/** Adapts a Node IncomingMessage into a Fetch Request. */
async function toRequest(req) {
  const url = `http://${req.headers.host ?? `127.0.0.1:${PORT}`}${req.url}`
  const headers = new Headers()
  for (const [key, value] of Object.entries(req.headers)) {
    if (typeof value === 'string') headers.set(key, value)
    else if (Array.isArray(value)) for (const v of value) headers.append(key, v)
  }
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD'
  let body
  if (hasBody) {
    const chunks = []
    for await (const chunk of req) chunks.push(chunk)
    body = Buffer.concat(chunks)
  }
  return new Request(url, { method: req.method, headers, body })
}

/** Writes a Fetch Response back to a Node ServerResponse. */
async function writeResponse(response, res) {
  res.statusCode = response.status
  response.headers.forEach((value, key) => res.setHeader(key, value))
  const text = await response.text()
  res.end(text)
}

const server = createServer(async (req, res) => {
  try {
    const request = await toRequest(req)
    const url = new URL(request.url)

    if (url.pathname === '/proof') {
      const result = await mppx.charge({
        amount: '0',
        description: 'Conformance: zero-amount proof of wallet control',
      })(request)
      if (result.status === 402) return await writeResponse(result.challenge, res)
      const ok = result.withReceipt(
        Response.json({ ok: true, paid: true, message: 'proof verified' }),
      )
      return await writeResponse(ok, res)
    }

    if (url.pathname === '/health') {
      return await writeResponse(Response.json({ status: 'ok' }), res)
    }

    res.statusCode = 404
    res.end('not found')
  } catch (error) {
    res.statusCode = 500
    res.end(`server error: ${error?.message ?? error}`)
  }
})

if (MODE === 'testnet') {
  await probeModerato()
}

server.listen(PORT, '127.0.0.1', () => {
  // The run script waits for this line before starting the Swift test.
  console.log(`conformance-server (${MODE}) listening http://127.0.0.1:${PORT}/proof`)
})
