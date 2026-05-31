// Cross-SDK MCP conformance (forward): the reference mppx `mcp-sdk` CLIENT pays OUR Swift MCP
// server (MPPMCPConformanceServer, spawned over stdio). The mppx client pays the zero-amount
// Tempo proof 402 our server issues, and reads back the receipt our server mints. OFFLINE and
// deterministic (ecrecover, no RPC).
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { McpClient, tempo } from 'mppx/mcp-sdk/client'
import { privateKeyToAccount } from 'viem/accounts'

const serverBin = process.env.SWIFT_MCP_SERVER
if (!serverBin) { console.error('SWIFT_MCP_SERVER not set'); process.exit(2) }

const account = privateKeyToAccount('0x' + '22'.repeat(32))
const transport = new StdioClientTransport({ command: serverBin, args: [] })
const client = new Client({ name: 'mppx-mcp-conformance-client', version: '1.0.0' })
await client.connect(transport)

const mcp = McpClient.wrap(client, { methods: [tempo.charge({ account })] })
const result = await mcp.callTool({ name: 'premium', arguments: {} })

const text = result.content?.[0]?.text ?? ''
if (!result.receipt) { console.error('FAIL: no receipt on the paid result'); await client.close(); process.exit(1) }
if (!text.includes('premium content')) { console.error('FAIL: unexpected content', JSON.stringify(result.content)); await client.close(); process.exit(1) }

console.log('PASS: mppx mcp-sdk client paid our Swift MCP server over stdio')
console.log('  receipt:', JSON.stringify(result.receipt))
console.log('  content:', text)
await client.close()
