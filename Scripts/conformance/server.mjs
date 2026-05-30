// Reference mppx (TypeScript) server for cross-SDK conformance testing.
//
// Boots a minimal HTTP server with a single endpoint that issues a zero-amount
// `tempo`/`charge` 402 challenge and verifies the proof credential the Swift
// client returns. The zero-amount proof is identity-only (EIP-712 ecrecover), so
// no Tempo RPC is contacted on the happy path; `testnet: true` fixes the chainId
// to Moderato (42431) without a network call.
//
// Dev-only harness. Not shipped. Run via `npm run serve` (see run.sh). The HTTP
// adapter + faucet helpers live in harness-http.mjs (shared with session-server.mjs).

import { Mppx, tempo } from 'mppx/server'
import { privateKeyToAccount } from 'viem/accounts'

import { rpc, serve } from './harness-http.mjs'

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
  const result = await rpc(MODERATO_RPC, 'eth_chainId', [])
  const chainId = Number(result)
  if (chainId !== 42431) throw new Error(`unexpected chainId ${chainId} (expected 42431)`)
  console.log(`moderato reachable: eth_chainId=${result} (${chainId})`)
}

async function handle(request, url) {
  if (url.pathname === '/proof') {
    const result = await mppx.charge({
      amount: '0',
      description: 'Conformance: zero-amount proof of wallet control',
    })(request)
    if (result.status === 402) return result.challenge
    return result.withReceipt(
      Response.json({ ok: true, paid: true, message: 'proof verified' }),
    )
  }
  if (url.pathname === '/health') return Response.json({ status: 'ok' })
  return new Response('not found', { status: 404 })
}

if (MODE === 'testnet') await probeModerato()

await serve({ name: `conformance-server (${MODE})`, port: PORT, path: '/proof', handle })
