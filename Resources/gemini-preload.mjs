import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Gemini CLI 0.70 keeps running after its stdin closes, unlike Claude and Codex, so a Mist quit,
// crash or chat close would orphan it and its MCP server. Exit with the pipe, as they do.
process.stdin.once('end', () => process.exit(0));

// Gemini CLI 0.70 keeps the resolved model ID for a tool continuation and
// drops the alias's generation options. Apply the chat selection to each
// streaming request, including those continuations.
const home = process.env.GEMINI_CLI_HOME;
if (home) {
  const fetchRequest = globalThis.fetch;
  const selectionPath = join(home, 'model-selection.json');
  globalThis.fetch = async (input, init) => {
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    const match = url.pathname.match(/^\/v1(?:beta)?\/models\/([^/:]+):streamGenerateContent$/);
    if (url.hostname !== 'generativelanguage.googleapis.com' || !match) {
      return fetchRequest(input, init);
    }
    const { model, thinkingLevel } = JSON.parse(readFileSync(selectionPath, 'utf8'));
    if (match[1] !== model) throw new Error('Gemini CLI changed the selected chat model');
    if (typeof init?.body !== 'string') throw new Error('Unexpected Gemini CLI request body');
    const body = JSON.parse(init.body);
    if (body.generationConfig?.thinkingConfig?.thinkingLevel === thinkingLevel) {
      return fetchRequest(input, init);
    }
    body.generationConfig ??= {};
    body.generationConfig.thinkingConfig ??= {};
    body.generationConfig.thinkingConfig.thinkingLevel = thinkingLevel;
    return fetchRequest(input, { ...init, body: JSON.stringify(body) });
  };
}
