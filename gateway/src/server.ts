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

// ---------- auth ----------

function userFromRequest(header: string | undefined): string | null {
  if (!header?.startsWith("Bearer ")) return null;
  return config.tokens.get(header.slice("Bearer ".length).trim()) ?? null;
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
  const userId = userFromRequest(req.header("authorization"));
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

    // Past the wait budget the client gets an ack and the drain continues in
    // the background; the final text is delivered as a proactive notification.
    const capTimer = setTimeout(
      () => finishClient("\n\nI'm still working on that. I'll let you know the moment it's done."),
      config.quickAnswerTimeoutMs,
    );

    try {
      const wasCappedBeforeFinal = () => clientDone;
      const finalText = await runTurnStreaming(sessionId, lastUser, drainContext(userId), (text) => {
        if (!clientDone) res.write(chunk({ content: text }));
      });
      clearTimeout(capTimer);
      if (wasCappedBeforeFinal()) {
        if (finalText && !notifyUser(userId, finalText)) {
          console.warn(`[turn] late streamed result for ${userId} had no connected client`);
        }
      } else {
        finishClient();
      }
    } catch (err) {
      clearTimeout(capTimer);
      console.error("[chat] streaming turn failed:", err);
      finishClient("Something went wrong while working on that. Try again in a moment.");
    }
    return;
  }

  try {
    const { sessionId } = await ensureUser(userId);
    // The session owns durable history; only the newest user turn is sent.
    const result = await runTurn(
      sessionId,
      lastUser,
      config.quickAnswerTimeoutMs,
      (lateText) => {
        const delivered = notifyUser(userId, lateText);
        if (!delivered) console.warn(`[turn] late result for ${userId} had no connected client`);
      },
      drainContext(userId),
    );

    const content = result.deferred
      ? "I'm still working on that. I'll let you know the moment it's done."
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

// Task history for the app's Recent Tasks view.
app.get("/tasks", async (req, res) => {
  const userId = userFromRequest(req.header("authorization"));
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
  const userId = userFromRequest(req.header("authorization"));
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
