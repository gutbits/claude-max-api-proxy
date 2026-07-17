/**
 * Model catalog — single source of truth for /v1/models and CLI --model mapping.
 */

export interface ModelEntry {
  id: string;
  cliModel: string;
  name: string;
  family: "opus" | "sonnet" | "haiku" | "fable";
}

export const ADVERTISED_MODELS: ModelEntry[] = [
  // Opus
  { id: "claude-opus-4-8", cliModel: "claude-opus-4-8", name: "Claude Opus 4.8", family: "opus" },
  { id: "claude-opus-4-7", cliModel: "claude-opus-4-7", name: "Claude Opus 4.7", family: "opus" },
  { id: "claude-opus-4-6", cliModel: "claude-opus-4-6", name: "Claude Opus 4.6", family: "opus" },
  { id: "claude-opus-4", cliModel: "opus", name: "Claude Opus (latest alias)", family: "opus" },
  { id: "opus", cliModel: "opus", name: "Opus alias", family: "opus" },
  { id: "opus-max", cliModel: "opus", name: "Opus Max alias", family: "opus" },
  // Sonnet
  { id: "claude-sonnet-5", cliModel: "claude-sonnet-5", name: "Claude Sonnet 5", family: "sonnet" },
  { id: "claude-sonnet-4-6", cliModel: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", family: "sonnet" },
  { id: "claude-sonnet-4-5", cliModel: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", family: "sonnet" },
  { id: "claude-sonnet-4", cliModel: "claude-sonnet-4", name: "Claude Sonnet 4 (legacy)", family: "sonnet" },
  { id: "sonnet", cliModel: "sonnet", name: "Sonnet alias (latest)", family: "sonnet" },
  { id: "sonnet-max", cliModel: "sonnet", name: "Sonnet Max alias", family: "sonnet" },
  // Haiku
  { id: "claude-haiku-4-5", cliModel: "claude-haiku-4-5", name: "Claude Haiku 4.5", family: "haiku" },
  { id: "claude-haiku-4", cliModel: "haiku", name: "Claude Haiku (latest alias)", family: "haiku" },
  { id: "haiku", cliModel: "haiku", name: "Haiku alias", family: "haiku" },
  // Fable
  { id: "claude-fable-5", cliModel: "claude-fable-5", name: "Claude Fable 5", family: "fable" },
  { id: "fable", cliModel: "fable", name: "Fable alias", family: "fable" },
  { id: "fable-max", cliModel: "fable", name: "Fable Max alias", family: "fable" },
];

const MODEL_BY_ID = new Map(ADVERTISED_MODELS.map((m) => [m.id, m]));

/**
 * Normalize model string from OpenAI/Hermes requests.
 * Handles: anthropic/claude-opus-4.8, custom:claude-max-proxy:claude-opus-4-8, etc.
 */
export function normalizeModelId(model: string): string {
  let m = model.trim();
  // Hermes / OpenRouter style prefixes
  m = m.replace(/^(?:anthropic|openrouter)\//i, "");
  // custom:provider:model or custom:model
  if (/^custom:/i.test(m)) {
    const parts = m.split(":");
    m = parts[parts.length - 1] || m;
  }
  // claude-code-cli/claude-opus-4-8
  m = m.replace(/^(?:claude-code-cli|claude-max)\//i, "");
  // claude-opus-4.8 -> claude-opus-4-8 (API uses dashes)
  m = m.replace(/(\d+)\.(\d+)/g, "$1-$2");
  return m.toLowerCase();
}

/**
 * Resolve OpenAI model ID to Claude CLI --model argument (full ID or alias).
 */
export function resolveCliModel(model: string): string {
  const id = normalizeModelId(model);
  const entry = MODEL_BY_ID.get(id);
  if (entry) return entry.cliModel;
  // Pass through explicit claude-* model IDs the CLI understands
  if (/^claude-[a-z0-9-]+$/i.test(id)) return id;
  if (/^(opus|sonnet|haiku|fable)$/i.test(id)) return id.toLowerCase();
  return "opus";
}

/**
 * Map CLI response model name back to advertised OpenAI model ID.
 */
export function displayModelId(cliModel: string | undefined, requestedModel?: string): string {
  if (requestedModel) {
    const reqId = normalizeModelId(requestedModel);
    if (MODEL_BY_ID.has(reqId)) return reqId;
    if (/^claude-[a-z0-9-]+$/i.test(reqId)) return reqId;
  }
  if (!cliModel) return "claude-sonnet-5";

  const raw = cliModel.toLowerCase().replace(/-20\d{6}$/, "");
  const normalized = normalizeModelId(raw);

  if (MODEL_BY_ID.has(normalized)) return normalized;

  // Match claude-opus-4-8-20260528 style snapshots
  for (const entry of ADVERTISED_MODELS) {
    if (normalized.startsWith(entry.id) || raw.includes(entry.id.replace(/^claude-/, ""))) {
      return entry.id;
    }
  }

  if (raw.includes("opus-4-8") || raw.includes("opus-4.8")) return "claude-opus-4-8";
  if (raw.includes("opus-4-7")) return "claude-opus-4-7";
  if (raw.includes("opus-4-6")) return "claude-opus-4-6";
  if (raw.includes("opus")) return "claude-opus-4";
  if (raw.includes("sonnet-5") || raw.includes("sonnet-5.")) return "claude-sonnet-5";
  if (raw.includes("sonnet-4-6")) return "claude-sonnet-4-6";
  if (raw.includes("sonnet-4-5")) return "claude-sonnet-4-5";
  if (raw.includes("sonnet")) return "claude-sonnet-5";
  if (raw.includes("haiku-4-5")) return "claude-haiku-4-5";
  if (raw.includes("haiku")) return "claude-haiku-4";
  if (raw.includes("fable")) return "claude-fable-5";

  return normalized || "claude-sonnet-5";
}

export function getAdvertisedModelIds(): string[] {
  // Dedupe — skip bare aliases in list shown to Hermes if we have full IDs
  const seen = new Set<string>();
  const ids: string[] = [];
  for (const m of ADVERTISED_MODELS) {
    if (!seen.has(m.id)) {
      seen.add(m.id);
      ids.push(m.id);
    }
  }
  return ids;
}
