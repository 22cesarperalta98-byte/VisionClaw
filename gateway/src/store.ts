import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

/**
 * Tiny JSON-file persistence for provisioned resource IDs.
 * Swap for Redis/Postgres when the user count justifies it - the interface is
 * three functions and one shape.
 */

export interface SharedResources {
  environmentId?: string;
  agentId?: string;
  agentVersion?: number;
}

export interface UserResources {
  memoryStoreId?: string;
  vaultId?: string;
  sessionId?: string;
  /** Task results that had no live channel to land on; drained at next call start. */
  pendingNotifications?: string[];
}

export interface StoreShape {
  shared: SharedResources;
  users: Record<string, UserResources>;
}

let cache: StoreShape | null = null;
let path = "./data/gateway-store.json";

export function initStore(storePath: string): void {
  path = storePath;
}

export async function loadStore(): Promise<StoreShape> {
  if (cache) return cache;
  try {
    cache = JSON.parse(await readFile(path, "utf8")) as StoreShape;
  } catch {
    cache = { shared: {}, users: {} };
  }
  return cache;
}

export async function saveStore(): Promise<void> {
  if (!cache) return;
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  await writeFile(tmp, JSON.stringify(cache, null, 2));
  await rename(tmp, path);
}

export async function userResources(userId: string): Promise<UserResources> {
  const store = await loadStore();
  store.users[userId] ??= {};
  return store.users[userId];
}
