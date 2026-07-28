import { anthropic } from "./cma.js";

export interface TaskSummary {
  id: string;
  ts: string | null;
  prompt: string;
  result: string;
}

function textOf(content: Array<{ type: string; text?: string }>): string {
  return content
    .filter((b) => b.type === "text" && b.text)
    .map((b) => b.text)
    .join("\n")
    .trim();
}

/**
 * Build a task history from the session's event log: each user.message is a
 * delegated task; the agent.message events that follow it (before the next
 * user.message) are its result.
 */
export async function listTasks(sessionId: string, limit: number): Promise<TaskSummary[]> {
  const events: Array<{ id: string; type: string; processed_at?: string | null; content?: unknown }> = [];
  for await (const ev of anthropic.beta.sessions.events.list(sessionId)) {
    events.push(ev as (typeof events)[number]);
    if (events.length >= 500) break;
  }

  const tasks: TaskSummary[] = [];
  let current: TaskSummary | null = null;

  for (const ev of events) {
    if (ev.type === "user.message") {
      if (current) tasks.push(current);
      current = {
        id: ev.id,
        ts: ev.processed_at ?? null,
        prompt: textOf((ev.content ?? []) as Array<{ type: string; text?: string }>),
        result: "",
      };
    } else if (ev.type === "agent.message" && current) {
      const text = textOf((ev.content ?? []) as Array<{ type: string; text?: string }>);
      if (text) current.result = current.result ? `${current.result}\n${text}` : text;
    }
  }
  if (current) tasks.push(current);

  return tasks.slice(-limit).reverse();
}
