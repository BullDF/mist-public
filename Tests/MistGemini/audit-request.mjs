import { appendFileSync } from 'node:fs';

// Observe the GenAI SDK's outbound request. Keep only the selected model, level and tool names.
const destination = process.env.MIST_GEMINI_AUDIT;
const fetchRequest = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
  const match = url.pathname.match(/\/models\/([^/:]+):(?:streamGenerateContent|generateContent)$/);
  if (destination && url.hostname === 'generativelanguage.googleapis.com' && match) {
    const raw = init?.body ?? (input instanceof Request ? await input.clone().text() : null);
    if (typeof raw === 'string') {
      const body = JSON.parse(raw);
      const tools = (body.tools ?? []).flatMap(tool =>
        tool.functionDeclarations?.map(declaration => declaration.name) ?? Object.keys(tool));
      appendFileSync(destination, JSON.stringify({
        model: match[1], thinking: body.generationConfig?.thinkingConfig?.thinkingLevel,
        tools: tools.sort(),
      }) + '\n');
    }
  }
  return fetchRequest(input, init);
};
