import { asString, asNumber, parseObject, parseJson } from "@paperclipai/adapter-utils/server-utils";

/**
 * OpenAI model pricing per million tokens (USD).
 * The Codex CLI does not emit cost data in its JSONL output, so we estimate
 * from token counts. Update these when OpenAI changes pricing.
 * Cached input tokens are priced at 50% of input (OpenAI standard discount).
 */
const MODEL_PRICING_PER_MILLION: Record<string, { input: number; output: number }> = {
  "gpt-5.4":             { input: 2.50, output: 10.00 },
  "gpt-5.4-mini":        { input: 0.40, output: 1.60 },
  "gpt-5.4-nano":        { input: 0.10, output: 0.40 },
  "gpt-5.4-pro":         { input: 10.00, output: 40.00 },
  "gpt-5.3-codex":       { input: 2.50, output: 10.00 },
  "gpt-5.2-codex":       { input: 2.50, output: 10.00 },
  "gpt-5.2":             { input: 2.50, output: 10.00 },
  "gpt-5.2-pro":         { input: 10.00, output: 40.00 },
  "gpt-5.1-codex":       { input: 2.00, output: 8.00 },
  "gpt-5.1-codex-mini":  { input: 0.30, output: 1.20 },
  "gpt-5.1-codex-max":   { input: 8.00, output: 32.00 },
  "gpt-5.1":             { input: 2.00, output: 8.00 },
  "gpt-5-codex":         { input: 2.00, output: 8.00 },
  "gpt-5":               { input: 2.00, output: 8.00 },
  "gpt-5-mini":          { input: 0.30, output: 1.20 },
  "gpt-5-nano":          { input: 0.10, output: 0.40 },
  "gpt-5-pro":           { input: 10.00, output: 40.00 },
};
const DEFAULT_PRICING = { input: 2.50, output: 10.00 };

function resolveModelPricing(model: string): { input: number; output: number } {
  if (!model) return DEFAULT_PRICING;
  const exact = MODEL_PRICING_PER_MILLION[model];
  if (exact) return exact;
  // Strip date suffixes (e.g., "gpt-5.3-codex-2026-01-15" → "gpt-5.3-codex")
  const stripped = model.replace(/-\d{4}-\d{2}-\d{2}$/, "");
  return MODEL_PRICING_PER_MILLION[stripped] ?? DEFAULT_PRICING;
}

export function estimateCostUsd(
  usage: { inputTokens: number; cachedInputTokens: number; outputTokens: number },
  model: string,
): number {
  const pricing = resolveModelPricing(model);
  const uncachedInput = Math.max(0, usage.inputTokens - usage.cachedInputTokens);
  const cachedInput = usage.cachedInputTokens;
  const inputCost = (uncachedInput / 1_000_000) * pricing.input;
  const cachedCost = (cachedInput / 1_000_000) * pricing.input * 0.5;
  const outputCost = (usage.outputTokens / 1_000_000) * pricing.output;
  return inputCost + cachedCost + outputCost;
}

export function parseCodexJsonl(stdout: string) {
  let sessionId: string | null = null;
  const messages: string[] = [];
  let errorMessage: string | null = null;
  const usage = {
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
  };

  for (const rawLine of stdout.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;

    const event = parseJson(line);
    if (!event) continue;

    const type = asString(event.type, "");
    if (type === "thread.started") {
      sessionId = asString(event.thread_id, sessionId ?? "") || sessionId;
      continue;
    }

    if (type === "error") {
      const msg = asString(event.message, "").trim();
      if (msg) errorMessage = msg;
      continue;
    }

    if (type === "item.completed") {
      const item = parseObject(event.item);
      if (asString(item.type, "") === "agent_message") {
        const text = asString(item.text, "");
        if (text) messages.push(text);
      }
      continue;
    }

    if (type === "turn.completed") {
      const usageObj = parseObject(event.usage);
      usage.inputTokens = asNumber(usageObj.input_tokens, usage.inputTokens);
      usage.cachedInputTokens = asNumber(usageObj.cached_input_tokens, usage.cachedInputTokens);
      usage.outputTokens = asNumber(usageObj.output_tokens, usage.outputTokens);
      continue;
    }

    if (type === "turn.failed") {
      const err = parseObject(event.error);
      const msg = asString(err.message, "").trim();
      if (msg) errorMessage = msg;
    }
  }

  return {
    sessionId,
    summary: messages.join("\n\n").trim(),
    usage,
    errorMessage,
  };
}

export function isCodexUnknownSessionError(stdout: string, stderr: string): boolean {
  const haystack = `${stdout}\n${stderr}`
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .join("\n");
  return /unknown (session|thread)|session .* not found|thread .* not found|conversation .* not found|missing rollout path for thread|state db missing rollout path/i.test(
    haystack,
  );
}
