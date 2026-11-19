// Local integration fixture. No network or filesystem writes.
const readline = require('node:readline');
const lines = readline.createInterface({ input: process.stdin });
lines.on('line', line => {
  const request = JSON.parse(line);
  if (request.id === undefined) return;
  let result;
  switch (request.method) {
    case 'initialize':
      result = { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'mist-test', version: '1' } };
      break;
    case 'tools/list':
      result = { tools: ['echo', 'poke'].map(name => ({ name, description: name === 'echo' ? 'Echo text without side effects' : 'Simulate a write, returning text only', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'], additionalProperties: false }, annotations: { readOnlyHint: name === 'echo', destructiveHint: false, openWorldHint: false } })) };
      break;
    case 'tools/call':
      result = { content: [{ type: 'text', text: `${request.params.name}: ${request.params.arguments.text}` }], isError: false };
      break;
    default: result = {};
  }
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\n');
});
