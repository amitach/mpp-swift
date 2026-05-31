// Reference mppx (TypeScript) SUBSCRIPTION server for cross-SDK activation conformance.
//
// Issues a `tempo`/`subscription` 402 carrying the server-issued access key, currency,
// recipient, period, and a whole-second expiry. The Swift client signs a TempoKeyAuthorization
// delegating that access key and POSTs the {type:"keyAuthorization", signature} credential; this
// server verifies the signed key authorization and activates. Activation signs no on-chain
// transaction, so the harness is fully OFFLINE (no faucet / RPC), deterministic, and cheap.
//
// Dev-only. Not shipped. Run via run-subscription.sh. HTTP adapter from harness-http.mjs.

import { Mppx, tempo } from 'mppx/server'
import { privateKeyToAccount } from 'viem/accounts'

import { serve } from './harness-http.mjs'

// Fixed keys for determinism. The operator owns the subscription method; the access account is the
// key the client's authorization delegates to. Neither signs on-chain (activation is offline).
const operator = privateKeyToAccount('0x' + '00'.repeat(31) + '07')
const accessAccount = privateKeyToAccount('0x' + '00'.repeat(31) + '08')
const accessKey = { accessKeyAddress: accessAccount.address, keyType: 'secp256k1' }

const currency = '0x20c0000000000000000000000000000000000001'
const recipient = '0x1111111111111111111111111111111111111111'
const chainId = 42431
const subscriptionExpires = new Date('2030-01-01T00:00:00.000Z')

const mppx = Mppx.create({
  secretKey: 'mpp-swift-subscription-conformance-fixed-secret-key-0123456789',
  methods: [
    // All route config lives on the method (matching the reference SDK's usage); the
    // per-request handler is `mppx.tempo.subscription({})(request)`.
    tempo.subscription({
      account: operator,
      amount: '1',
      decimals: 6,
      currency,
      recipient,
      chainId,
      periodCount: '30',
      periodUnit: 'day',
      subscriptionExpires,
      resolve: async () => ({ accessKey, key: 'sub-key' }),
      // Activation hook. The reference SDK has already verified the signed key
      // authorization by the time this runs (that is what the conformance proves); this
      // hook is the operator's settlement step. Activation is offline here, so it returns
      // a well-formed record + receipt with a synthetic transaction-hash reference (no
      // real transfer). The record fields mirror the request so the SDK's record/request
      // match check passes.
      activate: async ({ request, resolved }) => {
        const reference = '0x' + '11'.repeat(32)
        const timestamp = '2026-05-31T00:00:00.000Z'
        const subscription = {
          amount: request.amount,
          currency: request.currency,
          recipient: request.recipient,
          periodCount: request.periodCount,
          periodUnit: request.periodUnit,
          subscriptionExpires: request.subscriptionExpires,
          subscriptionId: 'sub1',
          lookupKey: resolved.key,
          lastChargedPeriod: 0,
          reference,
          timestamp,
          billingAnchor: timestamp,
          chainId: request.methodDetails?.chainId,
        }
        const receipt = {
          method: 'tempo',
          reference,
          status: 'success',
          subscriptionId: subscription.subscriptionId,
          timestamp,
        }
        return { subscription, receipt }
      },
    }),
  ],
})

const PORT = Number(process.env.PORT ?? 8791)

async function handle(request, url) {
  if (url.pathname === '/subscription') {
    const result = await mppx.tempo.subscription({})(request)
    if (result.status === 402) return result.challenge
    return result.withReceipt(Response.json({ ok: true, activated: true }))
  }
  if (url.pathname === '/health') return Response.json({ status: 'ok' })
  return new Response('not found', { status: 404 })
}

await serve({ name: 'subscription-conformance-server', port: PORT, path: '/subscription', handle })
