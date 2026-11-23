#!/usr/bin/env node
import { createInterface } from 'node:readline';

if (process.env.GEMINI_API_KEY !== 'fixture-key' || process.env.GOOGLE_API_KEY) process.exit(2);
const sessionId = 'gemini-fixture-session';
const send = fields => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...fields }) + '\n');
const update = update => send({ method: 'session/update', params: { sessionId, update } });
const text = text => update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } });
let waiting;
let stopped = false;
let modelId;
for await (const line of createInterface({ input: process.stdin })) {
  const { method, params, id, result } = JSON.parse(line);
  switch (method) {
    case 'initialize':
      send({ id, result: { protocolVersion: 1, authMethods: [{ id: 'gemini-api-key' }],
        agentCapabilities: { promptCapabilities: { image: true } } } });
      break;
    case 'authenticate':
      if (params.methodId !== 'gemini-api-key') process.exit(3);
      send({ id, result: {} });
      break;
    case 'session/new':
      send({ id, result: { sessionId } });
      break;
    case 'session/set_model':
      modelId = params.modelId;
      send({ id, result: {} });
      break;
    case 'session/prompt':
      if (!waiting && params.prompt[0].text === 'Permission probe') {
        waiting = id;
        const toolCall = { toolCallId: 'run_shell_command__example', title: 'printf ok', kind: 'execute', status: 'pending' };
        update({ sessionUpdate: 'tool_call', ...toolCall });
        send({ id: 'permission', method: 'session/request_permission', params: { sessionId, toolCall,
          options: [{ kind: 'allow_once', optionId: 'proceed_once' }, { kind: 'reject_once', optionId: 'cancel' }] } });
      } else {
        text(modelId + ': ' + params.prompt[0].text);
        update({ sessionUpdate: 'usage_update', used: 27, size: 1000 });
        send({ id, result: { stopReason: 'end_turn', usage: { outputTokens: 5 } } });
      }
      break;
    case 'session/cancel':
      stopped = true;
      break;
    default:
      if (id === 'permission' && waiting && stopped && result?.outcome?.outcome === 'cancelled') {
        send({ id: waiting, result: { stopReason: 'cancelled' } });
      } else {
        process.exit(4);
      }
  }
}
