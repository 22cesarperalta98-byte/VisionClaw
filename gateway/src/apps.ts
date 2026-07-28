/**
 * Connectable app registry.
 *
 * Adding an extension is one entry here plus (for MCP apps) one entry in the
 * agent config's `mcp_servers`. Credentials are stored per user in that user's
 * vault, keyed by the MCP server URL; Anthropic refreshes OAuth tokens.
 */

export interface ConnectableApp {
  id: string;
  displayName: string;
  /** MCP server the agent talks to. Vault credentials are matched to this URL. */
  mcpUrl: string;
  authorizeUrl: string;
  tokenUrl: string;
  scopes: string[];
  /** Extra params on the authorize URL (Google needs these to issue a refresh token). */
  authorizeParams?: Record<string, string>;
  clientIdEnv: string;
  clientSecretEnv: string;
}

export const APPS: Record<string, ConnectableApp> = {
  // KNOWN LIMITATION (verified 2026-07): Google's official Calendar MCP server
  // ships under the Google Workspace Developer Preview Program. With a personal
  // Gmail account, `initialize` and `tools/list` succeed but every `tools/call`
  // returns "The caller does not have permission" — reproduced with a direct
  // token call, so it is not a client or credential problem. The same token
  // works fine against the Calendar REST API. Using this from a consumer app
  // requires a Workspace account plus preview-program enrollment.
  //
  // For consumer users, wrap the Calendar REST API in a small MCP server of our
  // own and point `mcpUrl` at that instead; the vault credential mechanism is
  // unchanged. On-device EventKit tools cover interactive asks in the meantime.
  gcal: {
    id: "gcal",
    displayName: "Google Calendar",
    mcpUrl: "https://calendarmcp.googleapis.com/mcp/v1",
    authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    scopes: [
      "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
      "https://www.googleapis.com/auth/calendar.events.freebusy",
      "https://www.googleapis.com/auth/calendar.events.readonly",
    ],
    // offline + consent are required for Google to return a refresh_token.
    // Without a refresh token the vault credential dies within the hour.
    authorizeParams: { access_type: "offline", prompt: "consent", include_granted_scopes: "true" },
    clientIdEnv: "GOOGLE_CLIENT_ID",
    clientSecretEnv: "GOOGLE_CLIENT_SECRET",
  },
};

export function getApp(id: string): ConnectableApp | undefined {
  return APPS[id];
}

export function appCredentials(app: ConnectableApp): { clientId: string; clientSecret: string } | null {
  const clientId = process.env[app.clientIdEnv];
  const clientSecret = process.env[app.clientSecretEnv];
  if (!clientId || !clientSecret) return null;
  return { clientId, clientSecret };
}
