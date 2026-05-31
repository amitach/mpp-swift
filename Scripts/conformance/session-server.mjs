// Reference mppx (TypeScript) SESSION server for cross-SDK channel conformance.
//
// Issues a `tempo`/`session` 402 (non-zero), then for each credential the Swift client
// returns it acts on-chain on Moderato (42431): relays the client's signed `open`
// transaction, validates+records `voucher`s, and on `close` settles the latest voucher
// with the operator account (escrow.close). `testnet: true` auto-configures the Moderato
// RPC, escrow (0xe1c4...a336), and currency (pathUSD) from mppx's defaults; the operator
// is faucet-funded for gas before serving, so the harness is self-contained.
//
// Dev-only. Not shipped. Run via run-session.sh. HTTP adapter + faucet from harness-http.mjs.

import { Mppx, tempo } from 'mppx/server'
import { privateKeyToAccount } from 'viem/accounts'

import { fundAddress, serve } from './harness-http.mjs'

const MODERATO_RPC = 'https://rpc.moderato.tempo.xyz'
// The operator signs the on-chain close/settle. Fixed key for determinism; funded fresh
// from the faucet each run (gas only - the client funds its own channel deposit). Not a
// real fund.
const operator = privateKeyToAccount('0x' + '00'.repeat(31) + '04')

const mppx = Mppx.create({
  secretKey: 'mpp-swift-conformance-harness-fixed-secret-key-0123456789',
  methods: [
    tempo.session({
      account: operator, // signs the on-chain close/settle
      testnet: true, // -> chainId 42431, Moderato RPC, escrow 0xe1c4..a336, pathUSD
      suggestedDeposit: '1000', // advertised in the 402; the client deposits this to open
      waitForConfirmation: true, // relay the open and wait for its receipt before replying
    }),
  ],
})

// The per-request charge (base units of pathUSD); each accepted voucher accrues `amount`.
const route = mppx.session({ amount: '1', decimals: 6, unitType: 'token' })

const PORT = Number(process.env.PORT ?? 8790)

async function handle(request, url) {
  if (url.pathname === '/session') {
    const result = await route(request)
    if (result.status === 402) return result.challenge
    return result.withReceipt(Response.json({ ok: true, paid: true }))
  }
  if (url.pathname === '/health') return Response.json({ status: 'ok' })
  return new Response('not found', { status: 404 })
}

// Fund the operator's gas before serving: close/settle are real on-chain transactions.
console.log(`funding session operator ${operator.address} via faucet ...`)
await fundAddress(MODERATO_RPC, operator.address)
console.log('session operator funded')

await serve({ name: 'session-conformance-server', port: PORT, path: '/session', handle })
