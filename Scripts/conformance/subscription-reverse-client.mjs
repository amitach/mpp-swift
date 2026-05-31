// Reference mppx (TypeScript) SUBSCRIPTION client for reverse cross-SDK conformance.
//
// The mppx client activates a subscription against OUR Swift server
// (MPPConformanceServer + TempoSubscriptionVerifier): it reads our `tempo`/`subscription`
// 402, signs a TempoKeyAuthorization delegating the access key OUR challenge issued, and
// presents the {type:"keyAuthorization", signature} credential. A PASS means OUR verifier
// accepted the reference client's signed key authorization (the symmetric direction of
// run-subscription.sh). Offline: activation settles no transaction.
//
// Dev-only. Not shipped. Run via run-subscription-reverse.sh.

import { Mppx, tempo } from 'mppx/client'
import { privateKeyToAccount } from 'viem/accounts'

const url = process.env.SERVER_URL ?? 'http://127.0.0.1:8792/subscription'

// The root account that signs the key authorization. Local key (no wallet), so the
// access-key authorization path that would call a wallet is never exercised.
const account = privateKeyToAccount('0x' + '00'.repeat(31) + '09')

const client = Mppx.create({
  methods: [
    tempo.subscription({
      account,
      getClient: async () => ({
        request: async () => {
          throw new Error('wallet_authorizeAccessKey should not be called for a local account')
        },
      }),
    }),
  ],
})

const result = await client.fetch(url)
console.log(`[client] activate -> ${result.status}`)

if (!result.ok) {
  const body = await result.text().catch(() => '')
  console.error(`reverse subscription conformance FAILED: status=${result.status} ${body}`)
  process.exit(1)
}

console.log(`reverse subscription conformance PASSED: our server verified the mppx client's signed key authorization (${url})`)
