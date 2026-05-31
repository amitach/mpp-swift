// Cross-SDK MCP conformance (reverse): the reference mppx `mcp-sdk` SERVER gates a `premium` tool
// behind a zero-amount Tempo proof, over stdio. OUR Swift MCP client (MPPMCPConformanceClient)
// spawns this and pays it. Offline + deterministic (ecrecover, no RPC). Logs to stderr only;
// stdout carries the MCP JSON-RPC protocol.
import { Mppx, tempo, Transport } from 'mppx/server'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { privateKeyToAccount } from 'viem/accounts'

const account = privateKeyToAccount('0x' + '11'.repeat(32))
const payment = Mppx.create({
  realm: 'example',
  secretKey: 'mpp-swift-conformance-harness-fixed-secret-key-0123456789',
  methods: [tempo({ account, currency: '0x20c0000000000000000000000000000000000000', recipient: account.address, testnet: true })],
  transport: Transport.mcpSdk(),
})

const server = new McpServer({ name: 'mppx-mcp-conformance-server', version: '1.0.0' })
server.registerTool('premium', { description: 'A payment-gated tool' }, async (extra) => {
  const result = await payment.charge({ amount: '0', description: 'zero-amount proof' })(extra)
  if (result.status === 402) throw result.challenge
  return result.withReceipt({ content: [{ type: 'text', text: 'premium content' }] })
})

await server.connect(new StdioServerTransport())
console.error('mppx mcp-sdk server ready (stdio)')
