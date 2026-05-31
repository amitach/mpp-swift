// Shared harness plumbing for the conformance servers: the Node<->Fetch HTTP adapter
// and the Moderato faucet helpers. Both the proof server (server.mjs) and the session
// server (session-server.mjs) import these, so the glue lives in one place.
//
// Dev-only. Not shipped.

import { createServer } from 'node:http'

/** Adapts a Node IncomingMessage into a Fetch Request. */
export async function toRequest(req, boundPort) {
  const url = `http://${req.headers.host ?? `127.0.0.1:${boundPort}`}${req.url}`
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
export async function writeResponse(response, res) {
  res.statusCode = response.status
  response.headers.forEach((value, key) => res.setHeader(key, value))
  const text = await response.text()
  res.end(text)
}

/**
 * Boots an HTTP server. `handle(request, url)` returns a Fetch Response (or throws).
 * Resolves once listening, having logged `${name} listening http://127.0.0.1:PORT/...`
 * (the run script waits for "listening" and parses the bound port). PORT=0 asks the OS
 * for an ephemeral port; the logged port is the actually-bound one.
 */
export function serve({ name, port, path, handle }) {
  let boundPort = port
  const server = createServer(async (req, res) => {
    try {
      const request = await toRequest(req, boundPort)
      const response = await handle(request, new URL(request.url))
      await writeResponse(response, res)
    } catch (error) {
      res.statusCode = 500
      res.end(`server error: ${error?.message ?? error}`)
    }
  })
  return new Promise((resolve) => {
    server.listen(port, '127.0.0.1', () => {
      boundPort = server.address()?.port ?? port
      console.log(`${name} listening http://127.0.0.1:${boundPort}${path}`)
      resolve({ server, boundPort })
    })
  })
}

/** A single JSON-RPC call against an Ethereum-style node. Throws on a JSON-RPC error. */
export async function rpc(rpcUrl, method, params) {
  const response = await fetch(rpcUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  const json = await response.json()
  if (json.error) throw new Error(`${method} failed: ${JSON.stringify(json.error)}`)
  return json.result
}

/**
 * Funds `address` via the Moderato faucet (`tempo_fundAddress`: native gas + the TIP-20
 * tokens) and waits for the funding transactions to mine. The session server's operator
 * needs gas to relay/settle on-chain; the faucet makes the harness self-contained.
 */
export async function fundAddress(rpcUrl, address) {
  const hashes = await rpc(rpcUrl, 'tempo_fundAddress', [address])
  if (!Array.isArray(hashes) || hashes.length === 0) {
    throw new Error('faucet returned no funding transactions')
  }
  for (const hash of hashes) await waitForReceipt(rpcUrl, hash)
}

/** Polls `eth_getTransactionReceipt` until mined (status 0x1), up to ~60s. */
export async function waitForReceipt(rpcUrl, hash) {
  for (let i = 0; i < 60; i++) {
    const receipt = await rpc(rpcUrl, 'eth_getTransactionReceipt', [hash])
    if (receipt) {
      if (receipt.status !== '0x1') throw new Error(`tx ${hash} reverted`)
      return
    }
    await new Promise((r) => setTimeout(r, 1000))
  }
  throw new Error(`tx ${hash} not mined within 60s`)
}
