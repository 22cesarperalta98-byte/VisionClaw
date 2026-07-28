import { anthropic } from "./cma.js";

export interface TurnResult {
  /** Final text if it finished within the wait budget, else null. */
  text: string | null;
  /** True when the turn is still running and the result will arrive via onLateResult. */
  deferred: boolean;
}

/**
 * Run one conversational turn against a managed-agents session.
 *
 * Opens the event stream FIRST (events emitted before the stream opens are not
 * replayed), then sends the user message, then drains until the session goes
 * idle with a terminal stop reason. If the drain exceeds maxWaitMs the call
 * returns { deferred: true } and keeps consuming in the background; the final
 * text is delivered through onLateResult.
 */
export async function runTurn(
  sessionId: string,
  userText: string,
  maxWaitMs: number,
  onLateResult: (text: string) => void,
  contextNotes: string[] = [],
): Promise<TurnResult> {
  const stream = await anthropic.beta.sessions.events.stream(sessionId);

  // system.message events are only accepted immediately after a user.message
  // in the same request, so queued context rides along with the next turn.
  await anthropic.beta.sessions.events.send(sessionId, {
    events: [
      { type: "user.message", content: [{ type: "text", text: userText }] },
      ...contextNotes.map((note) => ({
        type: "system.message" as const,
        content: [{ type: "text" as const, text: note }],
      })),
    ],
  });

  const parts: string[] = [];
  let timedOut = false;

  const drain = (async () => {
    for await (const event of stream) {
      if (event.type === "agent.message") {
        for (const block of event.content) {
          if (block.type === "text") parts.push(block.text);
        }
      } else if (event.type === "session.error") {
        parts.push("Something went wrong while working on that. Try again in a moment.");
        break;
      } else if (event.type === "session.status_terminated") {
        break;
      } else if (event.type === "session.status_idle") {
        // Transient idle while the session waits on a client-side action is not
        // terminal; anything else means the turn is done.
        const reason = (event as { stop_reason?: { type?: string } }).stop_reason?.type;
        if (reason !== "requires_action") break;
      }
    }
    return parts.join("\n\n").trim();
  })();

  const timeout = new Promise<null>((resolve) => {
    setTimeout(() => {
      timedOut = true;
      resolve(null);
    }, maxWaitMs).unref?.();
  });

  const finished = await Promise.race([drain, timeout]);

  if (finished !== null) {
    return { text: finished || "Done.", deferred: false };
  }

  // Deferred: keep draining in the background and hand the result to the caller.
  void drain
    .then((text) => {
      if (timedOut && text) onLateResult(text);
    })
    .catch((err) => console.error("[turn] background drain failed:", err));

  return { text: null, deferred: true };
}

// ---------- queued context ----------
// The API rejects a standalone system.message, so context is queued per user
// and attached to that user's next turn. In-memory: acceptable loss on restart
// (context is advisory), persist alongside the store if that changes.

const pendingContext = new Map<string, string[]>();

/** Queue side-channel context (e.g. a voice-session summary) for the user's next turn. */
export function queueContext(userId: string, context: string): void {
  const list = pendingContext.get(userId) ?? [];
  list.push(`Context from the live voice session: ${context}`);
  // Keep only the most recent notes; old context goes stale fast.
  pendingContext.set(userId, list.slice(-5));
}

/** Drain queued context for a user (called when their next turn is sent). */
export function drainContext(userId: string): string[] {
  const list = pendingContext.get(userId) ?? [];
  pendingContext.delete(userId);
  return list;
}
