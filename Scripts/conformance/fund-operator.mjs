// Funds the reverse session server's operator address (derived from OPERATOR_KEY) via the
// Moderato faucet, so the server has gas to relay/settle on-chain. Run by
// run-session-reverse.sh before booting the Swift server. Reuses harness-http's faucet.
//
// Dev-only. Not shipped.

import { privateKeyToAccount } from 'viem/accounts'

import { fundAddress } from './harness-http.mjs'

const MODERATO_RPC = 'https://rpc.moderato.tempo.xyz'
const key = process.env.OPERATOR_KEY
if (!key) {
  console.error('OPERATOR_KEY not set')
  process.exit(1)
}
const account = privateKeyToAccount(key)
console.log(`funding operator ${account.address} via faucet ...`)
await fundAddress(MODERATO_RPC, account.address)
console.log('operator funded')
