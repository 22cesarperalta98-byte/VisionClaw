import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import express from "express";
import { WebSocketServer, type WebSocket } from "ws";
import { config } from "./config.js";
import { initStore } from "./store.js";
import { ensureUser } from "./provision.js";
import { runTurn, runTurnStreaming, queueContext, drainContext } from "./turn.js";
import { listTasks } from "./tasks.js";
import { registerSocket, notifyUser } from "./notify.js";
import { registerConnectRoutes } from "./connect.js";

initStore(config.storePath);

const app = express();
app.use(express.json({ limit: "1mb" }));

/**
 * What the voice model receives the instant a task is spawned.
 *
 * Deliberately an instruction, not a sentence to speak: a fixed string ("I'm
 * still working on that") gets read out verbatim and sounds like a status
 * message, whereas telling the model to acknowledge in its own words produces
 * cover that fits the conversation it is already having. The "do not answer
 * from memory" clause matters -- without it the model happily invents a
 * calendar rather than waiting for the real one.
 */
const SPAWN_ACK =
  "[task started] The request is running in the background. Tell the user briefly and naturally, " +
  "in your own words, that you're on it -- one short sentence, no promises about timing. " +
  "Do NOT answer the question yourself or guess at the content; the real result will arrive " +
  "shortly as a follow-up message for you to relay.";

// ---------- auth ----------

function userFromRequest(req: express.Request, explicitToken?: string): string | null {
  let token = explicitToken?.trim();
  if (!token) {
    const header = req.header("authorization");
    if (!header?.startsWith("Bearer ")) return null;
    token = header.slice("Bearer ".length).trim();
  }
  // The agent worker authenticates users upstream (LiveKit room identity), so
  // it holds one service credential and names the user per request.
  if (config.serviceToken && token === config.serviceToken) {
    const impersonated = req.header("x-user-id")?.trim();
    return impersonated || null;
  }
  return config.tokens.get(token) ?? null;
}

// ---------- app connections (OAuth -> vault) ----------

registerConnectRoutes(app, userFromRequest);

// ---------- HTTP: the app's existing protocol ----------

// Reachability probe: the app GETs this path and accepts any 2xx-4xx.
app.get("/v1/chat/completions", (_req, res) => {
  res.status(200).json({ ok: true, service: "visionclaw-gateway" });
});

app.get("/health", (_req, res) => {
  res.status(200).json({ ok: true });
});

// The app's delegateTask() posts OpenAI-style chat completions here.
app.post("/v1/chat/completions", async (req, res) => {
  const userId = userFromRequest(req);
  if (!userId) {
    res.status(401).json({ error: { message: "invalid or missing gateway token" } });
    return;
  }

  const messages = (req.body?.messages ?? []) as Array<{ role: string; content: string }>;
  const lastUser = [...messages].reverse().find((m) => m.role === "user")?.content?.trim();
  if (!lastUser) {
    res.status(400).json({ error: { message: "no user message found" } });
    return;
  }

  // ---- streaming path (OpenAI-style SSE chunks) ----
  if (req.body?.stream === true) {
    let sessionId: string;
    try {
      ({ sessionId } = await ensureUser(userId));
    } catch (err) {
      console.error("[chat] provisioning failed:", err);
      res.status(502).json({ error: { message: "agent backend error" } });
      return;
    }

    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache");
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();

    const id = `chatcmpl-${randomUUID()}`;
    const created = Math.floor(Date.now() / 1000);
    const chunk = (delta: object, finish: string | null = null) =>
      `data: ${JSON.stringify({
        id,
        object: "chat.completion.chunk",
        created,
        model: "visionclaw-cloud",
        choices: [{ index: 0, delta, finish_reason: finish }],
      })}\n\n`;
    res.write(chunk({ role: "assistant" }));

    let clientDone = false;
    const finishClient = (ackText?: string) => {
      if (clientDone) return;
      clientDone = true;
      if (ackText) res.write(chunk({ content: ackText }));
      res.write(chunk({}, "stop"));
      res.write("data: [DONE]\n\n");
      res.end();
    };
    res.on("close", () => {
      clientDone = true;
    });

    // In spawn mode the request never carries the result: acknowledge now, keep
    // draining, and deliver the answer over the WebSocket when it lands. The ack
    // is an instruction rather than a line to read out, so the cover comes back
    // in the assistant's own voice instead of a canned status message.
    if (config.spawnMode) finishClient(SPAWN_ACK);

    // Otherwise race the agent against the budget; past it, same deferral.
    const capTimer = config.spawnMode
      ? null
      : setTimeout(
          () => finishClient("\n\nI'm still working on that. I'll let you know the moment it's done."),
          config.quickAnswerTimeoutMs,
        );

    try {
      const wasCappedBeforeFinal = () => clientDone;
      const finalText = await runTurnStreaming(sessionId, lastUser, drainContext(userId), (text) => {
        if (!clientDone) res.write(chunk({ content: text }));
      });
      if (capTimer) clearTimeout(capTimer);
      if (wasCappedBeforeFinal()) {
        if (finalText && !notifyUser(userId, finalText)) {
          console.warn(`[turn] late streamed result for ${userId} had no connected client`);
        }
      } else {
        finishClient();
      }
    } catch (err) {
      if (capTimer) clearTimeout(capTimer);
      console.error("[chat] streaming turn failed:", err);
      finishClient("Something went wrong while working on that. Try again in a moment.");
    }
    return;
  }

  try {
    const { sessionId } = await ensureUser(userId);
    // The agent worker (service token) blocks on its own tool timeout and
    // relays the finished answer into the voice session -- handing IT the
    // spawn-mode acknowledgement would make the assistant read a status
    // message aloud. Spawn semantics are for the app's own HTTP calls.
    const bearer = req.header("authorization")?.slice("Bearer ".length).trim();
    const isServiceCall = !!config.serviceToken && bearer === config.serviceToken;
    // The session owns durable history; only the newest user turn is sent.
    const result = await runTurn(
      sessionId,
      lastUser,
      isServiceCall ? 110_000 : config.spawnMode ? 0 : config.quickAnswerTimeoutMs,
      (lateText) => {
        const delivered = notifyUser(userId, lateText);
        if (!delivered) console.warn(`[turn] late result for ${userId} had no connected client`);
      },
      drainContext(userId),
    );

    const content = result.deferred
      ? config.spawnMode
        ? SPAWN_ACK
        : "I'm still working on that. I'll let you know the moment it's done."
      : (result.text ?? "Done.");

    res.json({
      id: `chatcmpl-${randomUUID()}`,
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: "visionclaw-cloud",
      choices: [
        {
          index: 0,
          message: { role: "assistant", content },
          finish_reason: "stop",
        },
      ],
    });
  } catch (err) {
    console.error("[chat] turn failed:", err);
    res.status(502).json({ error: { message: "agent backend error" } });
  }
});

// LiveKit room ticket: the phone trades its gateway token for a short-lived
// room JWT. The LiveKit API secret never leaves the server, and each user gets
// their own room -- the same isolation boundary as their CMA session.
app.post("/livekit-token", async (req, res) => {
  const userId = userFromRequest(req);
  if (!userId) {
    res.status(401).json({ error: { message: "invalid or missing gateway token" } });
    return;
  }
  const { LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET } = process.env;
  if (!LIVEKIT_URL || !LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) {
    res.status(503).json({ error: { message: "LiveKit is not configured on this gateway" } });
    return;
  }
  const { AccessToken } = await import("livekit-server-sdk");
  // The engine choice (gemini | openai) rides as participant metadata; the
  // worker reads it when the user joins and picks the realtime model.
  const engine = req.body?.engine === "openai" ? "openai" : "gemini";
  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: userId,
    ttl: "15m",
    metadata: JSON.stringify({ engine }),
  });
  const room = `vc-${userId}`;
  at.addGrant({ roomJoin: true, room, canPublish: true, canSubscribe: true });
  res.json({ url: LIVEKIT_URL, room, token: await at.toJwt() });
});

// Task history for the app's Recent Tasks view.
app.get("/tasks", async (req, res) => {
  const userId = userFromRequest(req);
  if (!userId) {
    res.status(401).json({ error: { message: "invalid or missing gateway token" } });
    return;
  }
  const limit = Math.min(Number(req.query.limit ?? 20) || 20, 100);
  try {
    const { sessionId } = await ensureUser(userId);
    res.json({ tasks: await listTasks(sessionId, limit) });
  } catch (err) {
    console.error("[tasks] listing failed:", err);
    res.status(502).json({ error: { message: "agent backend error" } });
  }
});

// Voice-session context handoff (summaries, what the user is looking at).
app.post("/context", async (req, res) => {
  const userId = userFromRequest(req);
  if (!userId) {
    res.status(401).json({ error: { message: "invalid or missing gateway token" } });
    return;
  }
  const context = String(req.body?.context ?? "").trim();
  if (!context) {
    res.status(400).json({ error: { message: "context is required" } });
    return;
  }
  // Queued (not sent immediately): the API only accepts system.message events
  // trailing a user.message, so this rides along with the user's next turn.
  queueContext(userId, context);
  res.sendStatus(204);
});

// ---------- WS: the app's event channel (protocol v3 handshake) ----------

const httpServer = createServer(app);
const wss = new WebSocketServer({ server: httpServer });

wss.on("connection", (ws: WebSocket) => {
  // Mirror the local gateway's opening move so OpenClawEventClient handshakes unchanged.
  ws.send(JSON.stringify({ type: "event", event: "connect.challenge", payload: {} }));

  ws.on("message", (raw) => {
    let msg: { type?: string; id?: string; method?: string; params?: { auth?: { token?: string } } };
    try {
      msg = JSON.parse(String(raw));
    } catch {
      return;
    }
    if (msg.type !== "req" || msg.method !== "connect") return;

    const token = msg.params?.auth?.token;
    const userId = token ? (config.tokens.get(token) ?? null) : null;
    if (!userId) {
      ws.send(
        JSON.stringify({ type: "res", id: msg.id, ok: false, error: { message: "invalid token" } }),
      );
      ws.close();
      return;
    }

    registerSocket(userId, ws);
    ws.send(JSON.stringify({ type: "res", id: msg.id, ok: true }));
    console.log(`[ws] client connected for ${userId}`);
  });
});

httpServer.listen(config.port, () => {
  console.log(`[gateway] listening on :${config.port}`);
  console.log(`[gateway] app settings -> host: http://<this-host>  port: ${config.port}`);
});
