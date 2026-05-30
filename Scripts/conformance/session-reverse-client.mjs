// Reverse channel conformance: the reference mppx (TypeScript) CLIENT opens a payment
// channel against OUR Swift server (MPPConformanceServer's /session route, backed by
// SessionMethod + RPCChannelStateProvider), vouchers, and closes, live on Moderato. A PASS
// means our server relayed the foreign client's open on-chain, accepted its vouchers, and
// settled its close (escrow.close) with our operator. The mirror of the forward direction.
//
// Dev-only. Run via run-session-reverse.sh (which funds our operator + boots the Swift
// server first). Self-contained: the mppx client funds its own channel from the faucet.

import { tempo } from 'mppx/client'
import { privateKeyToAccount } from 'viem/accounts'

import { fundAddress } from './harness-http.mjs'

const MODERATO_RPC = 'https://rpc.moderato.tempo.xyz'
const url = process.env.SERVER_URL ?? 'http://127.0.0.1:8799/session'
// Fixed client key for determinism; funded fresh from the faucet (gas + the TIP-20 it
// deposits to open the channel). Distinct from the server's operator key.
const account = privateKeyToAccount('0x' + '00'.repeat(31) + '07')

console.log(`[client] funding ${account.address} via faucet ...`)
await fundAddress(MODERATO_RPC, account.address)
console.log('[client] funded')

// sessionManager (tempo.session on the client) drives the channel lifecycle: open on the
// first paid request, incremental vouchers, then close. maxDeposit enables auto-management
// and caps the server's suggestedDeposit; testnet wires the Moderato RPC.
const manager = tempo.session({ account, maxDeposit: '1000', testnet: true })

const first = await manager.fetch(url) // opens the channel (our server relays it on-chain)
console.log(`[client] open  -> ${first.status}`)
const second = await manager.fetch(url) // vouchers against the open channel
console.log(`[client] voucher -> ${second.status}`)
const receipt = await manager.close() // our server settles the voucher on-chain (close)
console.log(`[client] close -> channelId=${receipt?.channelId ?? 'n/a'}`)

if (!first.ok || !second.ok) {
  console.error(`reverse session conformance FAILED: open=${first.status} voucher=${second.status}`)
  process.exit(1)
}
console.log(`reverse session conformance PASSED: mppx client open+voucher+close settled by our server (${url})`)
