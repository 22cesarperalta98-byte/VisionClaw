import "dotenv/config";

export interface GatewayConfig {
  port: number;
  storePath: string;
  /** token -> userId. Parsed from GATEWAY_TOKENS="tokenA:alice,tokenB:bob". */
  tokens: Map<string, string>;
  agentModel: string;
  agentEffort: "low" | "medium" | "high";
  /** How long a /v1/chat/completions call waits before converting to a background task. */
  quickAnswerTimeoutMs: number;
}

function parseTokens(raw: string | undefined): Map<string, string> {
  const map = new Map<string, string>();
  if (!raw) return map;
  for (const pair of raw.split(",")) {
    const [token, userId] = pair.split(":").map((s) => s.trim());
    if (token && userId) map.set(token, userId);
  }
  return map;
}

export const config: GatewayConfig = {
  port: Number(process.env.PORT ?? 8788),
  storePath: process.env.STORE_PATH ?? "./data/gateway-store.json",
  tokens: parseTokens(process.env.GATEWAY_TOKENS),
  agentModel: process.env.AGENT_MODEL ?? "claude-opus-5",
  agentEffort: (process.env.AGENT_EFFORT as GatewayConfig["agentEffort"]) ?? "medium",
  quickAnswerTimeoutMs: Number(process.env.QUICK_ANSWER_TIMEOUT_MS ?? 30_000),
};

if (config.tokens.size === 0) {
  console.warn(
    "[config] GATEWAY_TOKENS is empty - no client will be able to authenticate. " +
      'Set GATEWAY_TOKENS="sometoken:someUserId" in .env',
  );
}
