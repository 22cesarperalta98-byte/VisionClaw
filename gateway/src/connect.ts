import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { Express, Request, Response } from "express";
import { anthropic } from "./cma.js";
import { appCredentials, getApp, APPS } from "./apps.js";
import { ensureUser } from "./provision.js";
import { notifyUser } from "./notify.js";

/**
 * One-tap app connection: /connect/:app redirects to the provider, the callback
 * exchanges the code and writes an mcp_oauth credential into the user's vault.
 * Anthropic refreshes the token from there on, so this runs once per user per app.
 */

const STATE_TTL_MS = 10 * 60 * 1000;

function stateSecret(): string {
  return process.env.STATE_SECRET ?? "dev-only-insecure-state-secret";
}

function signState(userId: string, appId: string): string {
  const payload = `${userId}:${appId}:${Date.now()}:${randomBytes(8).toString("hex")}`;
  const mac = createHmac("sha256", stateSecret()).update(payload).digest("hex").slice(0, 32);
  return Buffer.from(`${payload}:${mac}`).toString("base64url");
}

function verifyState(state: string): { userId: string; appId: string } | null {
  let decoded: string;
  try {
    decoded = Buffer.from(state, "base64url").toString("utf8");
  } catch {
    return null;
  }
  const parts = decoded.split(":");
  if (parts.length !== 5) return null;
  const [userId, appId, issuedAt, nonce, mac] = parts;
  const expected = createHmac("sha256", stateSecret())
    .update(`${userId}:${appId}:${issuedAt}:${nonce}`)
    .digest("hex")
    .slice(0, 32);
  const a = Buffer.from(mac);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  if (Date.now() - Number(issuedAt) > STATE_TTL_MS) return null;
  return { userId, appId };
}

function redirectUri(req: Request, appId: string): string {
  const base = process.env.PUBLIC_BASE_URL ?? `${req.protocol}://${req.get("host")}`;
  return `${base}/connect/${appId}/callback`;
}

function page(title: string, body: string): string {
  return `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:17px -apple-system,system-ui,sans-serif;margin:0;display:grid;place-items:center;height:100vh;text-align:center;padding:24px;color:#111}
h1{font-size:20px;margin:0 0 8px}p{color:#666;margin:0;max-width:28em}</style>
<h1>${title}</h1><p>${body}</p>`;
}

export function registerConnectRoutes(
  app: Express,
  userFromRequest: (header: string | undefined) => string | null,
): void {
  // What's connectable and what this user has already connected.
  app.get("/apps", async (req: Request, res: Response) => {
    const userId = userFromRequest(req.header("authorization"));
    if (!userId) {
      res.status(401).json({ error: { message: "invalid or missing gateway token" } });
      return;
    }
    try {
      const { vaultId } = await ensureUser(userId);
      const connected = new Set<string>();
      for await (const cred of anthropic.beta.vaults.credentials.list(vaultId)) {
        const url = (cred as { auth?: { mcp_server_url?: string } }).auth?.mcp_server_url;
        if (url) connected.add(url);
      }
      res.json({
        apps: Object.values(APPS).map((a) => ({
          id: a.id,
          displayName: a.displayName,
          connected: connected.has(a.mcpUrl),
          available: appCredentials(a) !== null,
        })),
      });
    } catch (err) {
      console.error("[apps] listing failed:", err);
      res.status(502).json({ error: { message: "could not list apps" } });
    }
  });

  // Start the flow. Opened in an in-app auth sheet; token in the query so the
  // sheet does not need to set headers.
  app.get("/connect/:appId", (req: Request, res: Response) => {
    const token = String(req.query.token ?? "");
    const userId = userFromRequest(token ? `Bearer ${token}` : undefined);
    if (!userId) {
      res.status(401).send(page("Not signed in", "Open this from the VisionClaw app."));
      return;
    }
    const appDef = getApp(String(req.params.appId));
    if (!appDef) {
      res.status(404).send(page("Unknown app", "That integration does not exist."));
      return;
    }
    const creds = appCredentials(appDef);
    if (!creds) {
      res.status(503).send(page("Not configured", `${appDef.displayName} is not set up on this gateway yet.`));
      return;
    }

    const params = new URLSearchParams({
      client_id: creds.clientId,
      redirect_uri: redirectUri(req, appDef.id),
      response_type: "code",
      scope: appDef.scopes.join(" "),
      state: signState(userId, appDef.id),
      ...(appDef.authorizeParams ?? {}),
    });
    res.redirect(`${appDef.authorizeUrl}?${params.toString()}`);
  });

  // Provider redirects here: exchange the code, store the credential.
  app.get("/connect/:appId/callback", async (req: Request, res: Response) => {
    const appDef = getApp(String(req.params.appId));
    if (!appDef) {
      res.status(404).send(page("Unknown app", "That integration does not exist."));
      return;
    }
    if (req.query.error) {
      res.status(400).send(page("Connection cancelled", "You can close this window and try again."));
      return;
    }

    const verified = verifyState(String(req.query.state ?? ""));
    const code = String(req.query.code ?? "");
    if (!verified || verified.appId !== appDef.id || !code) {
      res.status(400).send(page("Could not connect", "The sign-in link expired. Please try again from the app."));
      return;
    }

    const creds = appCredentials(appDef);
    if (!creds) {
      res.status(503).send(page("Not configured", `${appDef.displayName} is not set up on this gateway yet.`));
      return;
    }

    try {
      const tokenRes = await fetch(appDef.tokenUrl, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          code,
          client_id: creds.clientId,
          client_secret: creds.clientSecret,
          redirect_uri: redirectUri(req, appDef.id),
          grant_type: "authorization_code",
        }),
      });
      if (!tokenRes.ok) {
        console.error("[connect] token exchange failed:", tokenRes.status, await tokenRes.text());
        res.status(502).send(page("Could not connect", "The provider rejected the sign-in. Please try again."));
        return;
      }

      const tokens = (await tokenRes.json()) as {
        access_token: string;
        refresh_token?: string;
        expires_in?: number;
        scope?: string;
      };

      // Granted scopes can be narrower than requested (the user can decline
      // individual permissions), which surfaces later as opaque "caller does not
      // have permission" errors from the provider. Log what we actually got.
      const granted = (tokens.scope ?? "").split(" ").filter(Boolean);
      const missing = appDef.scopes.filter((s) => !granted.includes(s));
      console.log(`[connect] ${appDef.id} granted scopes:`, granted.join(" ") || "(none reported)");
      if (missing.length > 0) {
        console.warn(`[connect] ${appDef.id} MISSING scopes:`, missing.join(" "));
      }

      // DIAG=1: probe the provider directly with the fresh token, so an opaque
      // "permission denied" from the agent can be attributed to the token, the
      // REST API, or the MCP endpoint specifically.
      if (process.env.DIAG === "1") {
        try {
          const rest = await fetch("https://www.googleapis.com/calendar/v3/users/me/calendarList", {
            headers: { Authorization: `Bearer ${tokens.access_token}` },
          });
          console.log("[diag] calendar REST status:", rest.status, (await rest.text()).slice(0, 300));
          const mcpCall = async (label: string, body: object) => {
            const r = await fetch(appDef.mcpUrl, {
              method: "POST",
              headers: {
                Authorization: `Bearer ${tokens.access_token}`,
                "Content-Type": "application/json",
                Accept: "application/json, text/event-stream",
              },
              body: JSON.stringify(body),
            });
            console.log(`[diag] MCP ${label}:`, r.status, (await r.text()).slice(0, 600));
          };
          await mcpCall("initialize", {
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: {
              protocolVersion: "2025-06-18",
              capabilities: {},
              clientInfo: { name: "visionclaw-diag", version: "0.1.0" },
            },
          });
          await mcpCall("tools/list", { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
          // The operation the agent actually fails on.
          await mcpCall("tools/call list_calendars", {
            jsonrpc: "2.0",
            id: 3,
            method: "tools/call",
            params: { name: "list_calendars", arguments: {} },
          });
        } catch (e) {
          console.warn("[diag] probe failed:", e);
        }
      }

      const { vaultId } = await ensureUser(verified.userId);

      // One credential per MCP server URL: replace any existing one.
      for await (const cred of anthropic.beta.vaults.credentials.list(vaultId)) {
        const url = (cred as { auth?: { mcp_server_url?: string } }).auth?.mcp_server_url;
        if (url === appDef.mcpUrl) {
          await anthropic.beta.vaults.credentials.delete(cred.id, { vault_id: vaultId });
        }
      }

      await anthropic.beta.vaults.credentials.create(vaultId, {
        display_name: `${appDef.displayName} (${verified.userId})`,
        auth: {
          type: "mcp_oauth",
          mcp_server_url: appDef.mcpUrl,
          access_token: tokens.access_token,
          expires_at: tokens.expires_in
            ? new Date(Date.now() + tokens.expires_in * 1000).toISOString()
            : undefined,
          // Without refresh, access dies with the first token expiry.
          refresh: tokens.refresh_token
            ? {
                refresh_token: tokens.refresh_token,
                client_id: creds.clientId,
                token_endpoint: appDef.tokenUrl,
                token_endpoint_auth: {
                  type: "client_secret_post",
                  client_secret: creds.clientSecret,
                },
              }
            : undefined,
        },
      });

      if (!tokens.refresh_token) {
        console.warn(
          `[connect] ${appDef.id} returned no refresh_token for ${verified.userId};` +
            " access will expire. Check access_type=offline and prompt=consent.",
        );
      }

      console.log(`[connect] ${appDef.displayName} connected for ${verified.userId}`);
      notifyUser(verified.userId, `${appDef.displayName} is connected.`);
      res.send(page(`${appDef.displayName} connected`, "You can close this window and keep talking."));
    } catch (err) {
      console.error("[connect] callback failed:", err);
      res.status(502).send(page("Could not connect", "Something went wrong. Please try again."));
    }
  });
}
