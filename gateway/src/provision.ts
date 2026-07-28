import { anthropic } from "./cma.js";
import { config } from "./config.js";
import { loadStore, saveStore, userResources, type UserResources } from "./store.js";

const AGENT_SYSTEM_PROMPT = `You are the action agent behind a voice assistant that runs on smart glasses and phones.
The user talks to a real-time voice layer; that layer delegates tasks to you and speaks your replies aloud.

Ground rules:
- Reply in plain spoken prose. No markdown, no headers, no bullet lists, no URLs read out character by character.
- Lead with the answer in one or two sentences. Add detail only when the task genuinely needs it.
- You have a mounted memory directory about the owner. Check it before tasks that depend on their preferences,
  people, or ongoing threads, and append new durable facts as you learn them. Never store secrets there.
- For multi-step work, start immediately and keep intermediate narration to a single short sentence.
- If a task cannot be completed, say what you tried and what is missing, in one sentence.`;

/** Create the shared environment + agent once; IDs persist in the store. */
export async function ensureShared(): Promise<{ agentId: string; environmentId: string }> {
  const store = await loadStore();
  if (!store.shared.environmentId) {
    const env = await anthropic.beta.environments.create({
      name: "visionclaw-cloud",
      config: { type: "cloud", networking: { type: "unrestricted" } },
    });
    store.shared.environmentId = env.id;
    console.log("[provision] environment created:", env.id);
  }
  if (!store.shared.agentId) {
    const agent = await anthropic.beta.agents.create({
      name: "VisionClaw Action Agent",
      model: { id: config.agentModel, effort: config.agentEffort },
      system: AGENT_SYSTEM_PROMPT,
      tools: [{ type: "agent_toolset_20260401" }],
    });
    store.shared.agentId = agent.id;
    store.shared.agentVersion = agent.version;
    console.log("[provision] agent created:", agent.id, "version", agent.version);
  }
  await saveStore();
  return { agentId: store.shared.agentId, environmentId: store.shared.environmentId };
}

async function sessionUsable(sessionId: string): Promise<boolean> {
  try {
    const s = await anthropic.beta.sessions.retrieve(sessionId);
    return s.status !== "terminated" && s.archived_at == null;
  } catch {
    return false;
  }
}

/**
 * Lazily provision a user's memory store, vault, and long-lived session.
 * Continuity lives in the memory store: if the session ever terminates, a new
 * one is created with the same store mounted.
 */
export async function ensureUser(userId: string): Promise<Required<UserResources>> {
  const { agentId, environmentId } = await ensureShared();
  const u = await userResources(userId);

  if (!u.memoryStoreId) {
    const memStore = await anthropic.beta.memoryStores.create({
      name: `visionclaw-memory-${userId}`,
      description:
        "Long-term memory about the owner: preferences, people, places, routines, and ongoing threads. " +
        "Read before starting tasks; append durable new facts. Never store credentials or secrets.",
    });
    u.memoryStoreId = memStore.id;
    console.log(`[provision] memory store for ${userId}:`, memStore.id);
  }

  if (!u.vaultId) {
    const vault = await anthropic.beta.vaults.create({ display_name: `visionclaw-vault-${userId}` });
    u.vaultId = vault.id;
    console.log(`[provision] vault for ${userId}:`, vault.id);
  }

  if (!u.sessionId || !(await sessionUsable(u.sessionId))) {
    const session = await anthropic.beta.sessions.create({
      agent: agentId,
      environment_id: environmentId,
      title: `visionclaw:${userId}`,
      vault_ids: [u.vaultId],
      resources: [
        {
          type: "memory_store",
          memory_store_id: u.memoryStoreId,
          access: "read_write",
          instructions:
            "Your long-term memory about the owner. Check it before tasks; write durable facts back as you learn them.",
        },
      ],
    });
    u.sessionId = session.id;
    console.log(`[provision] session for ${userId}:`, session.id);
  }

  await saveStore();
  return u as Required<UserResources>;
}
