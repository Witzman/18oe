import type { MapGeometry } from "./render/mapdata.ts";
import type { Account, Game, GameSummary, SeatRequest, Version } from "./types.ts";

export class ApiError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

// Typed wrapper around the endpoints of #33/#36. The server error format is
// always {error, message}; anything else is reported as a network/protocol error.
export function createApi(fetchFn: FetchLike = (i, init) => fetch(i, init)) {
  async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const init: RequestInit = { method, credentials: "same-origin", headers: { Accept: "application/json" } };
    if (body !== undefined) {
      init.body = JSON.stringify(body);
      init.headers = { ...init.headers, "Content-Type": "application/json" };
    }
    let res: Response;
    try {
      res = await fetchFn(path, init);
    } catch (e) {
      throw new ApiError(0, "network", e instanceof Error ? e.message : "network error");
    }
    let data: unknown = null;
    try {
      data = await res.json();
    } catch {
      /* non-JSON body: handled below */
    }
    if (!res.ok) {
      const err = (data ?? {}) as { error?: string; message?: string };
      throw new ApiError(res.status, err.error ?? "http_error", err.message ?? `HTTP ${res.status}`);
    }
    return data as T;
  }

  return {
    me: () => call<Account>("GET", "/me"),
    map: () => call<MapGeometry>("GET", "/map"),
    accounts: (code: string) => call<{ accounts: Account[] }>("POST", "/accounts", { code }),
    login: (account: string, code: string) => call<Account>("POST", "/login", { account, code }),
    logout: () => call<{ ok: boolean }>("POST", "/logout"),
    listGames: () => call<{ games: GameSummary[] }>("GET", "/games"),
    createGame: (seats: SeatRequest[]) => call<Game>("POST", "/games", { seats }),
    getGame: (id: number, log = 40) => call<Game>("GET", `/games/${id}?log=${log}`),
    version: (id: number) => call<Version>("GET", `/games/${id}/version`),
    postAction: (id: number, action: Record<string, unknown>, seq: number) =>
      call<Game>("POST", `/games/${id}/actions`, { action, seq }),
  };
}

export type Api = ReturnType<typeof createApi>;
