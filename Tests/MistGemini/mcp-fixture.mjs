import { createInterface } from 'node:readline';

for await (const line of createInterface({ input: process.stdin })) {
  const { id, method, params } = JSON.parse(line);
  if (id === undefined) continue;
  const results = {
    initialize: {
      protocolVersion: params?.protocolVersion, capabilities: { tools: {}, resources: {} },
      serverInfo: { name: 'mistbrowser-fixture', version: '1' },
    },
    'tools/list': {
      tools: [{
        name: 'fixture_status', description: 'Returns an inert fixture status.',
        inputSchema: { type: 'object', properties: {} },
      }],
    },
    'resources/list': { resources: [{ uri: 'fixture://example/status', name: 'Fixture status', mimeType: 'text/plain' }] },
    'resources/read': { contents: [{ uri: 'fixture://example/status', mimeType: 'text/plain', text: 'Ready.' }] },
    'resources/templates/list': { resourceTemplates: [] },
  };
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result: results[method] ?? {} }) + '\n');
}
