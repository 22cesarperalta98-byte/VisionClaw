import type { WebSocket } from "ws";

/**
 * Registry of connected app sockets per user, plus helpers that emit events in
 * the exact shape the VisionClaw clients already parse (OpenClawEventClient):
 *   - assistant notifications ride the "heartbeat" event (status "sent" + preview)
 *   - scheduled-task results ride the "cron" event (action "finished" + summary)
 */

const sockets = new Map<string, Set<WebSocket>>();

export function registerSocket(userId: string, ws: WebSocket): void {
  let set = sockets.get(userId);
  if (!set) {
    set = new Set();
    sockets.set(userId, set);
  }
  set.add(ws);
  ws.on("close", () => {
    set.delete(ws);
    if (set.size === 0) sockets.delete(userId);
  });
}

function broadcast(userId: string, message: unknown): boolean {
  const set = sockets.get(userId);
  if (!set || set.size === 0) return false;
  const payload = JSON.stringify(message);
  for (const ws of set) {
    if (ws.readyState === ws.OPEN) ws.send(payload);
  }
  return true;
}

/** Push an assistant notification; the app renders it as a proactive message. */
export function notifyUser(userId: string, preview: string): boolean {
  return broadcast(userId, {
    type: "event",
    event: "heartbeat",
    payload: { status: "sent", preview, silent: false },
  });
}

/** Push a finished scheduled-task summary. */
export function notifyScheduled(userId: string, summary: string): boolean {
  return broadcast(userId, {
    type: "event",
    event: "cron",
    payload: { action: "finished", summary },
  });
}
