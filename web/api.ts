import type { MapGeometry } from "./render/mapdata.ts";
import type { Account, Game, GameSummary, LogPage, SeatRequest, Version } from "./types.ts";

export class ApiError extends Error {
  status: number;
  code: string;
  // Which request failed and after how long (#294): shown in the connection band, so a failure never hides
  // behind "no connection". Empty/null when the error did not come from a request.
  request: string;
  elapsedMs: number | null;
  constructor(status: number, code: string, message: string, request = "", elapsedMs: number | null = null) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.request = request;
    this.elapsedMs = elapsedMs;
  }
}

// A GET that has not answered after this long is aborted and reported as a timeout (#294); the poller
// retries. Actions (POST) have their own limit (POST_TIMEOUT_MS, #289).
export const GET_TIMEOUT_MS = 30000;

export interface RegisterRequest { name: string; email: string; password: string; code: string }

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export const POST_TIMEOUT_MS = 30_000;

// Typed wrapper around the endpoints of #33/#36. The server error format is
// always {error, message}; anything else is reported as a network/protocol error.
export function createApi(fetchFn: FetchLike = (i, init) => fetch(i, init), opts: { getTimeoutMs?: number; postTimeoutMs?: number; now?: () => number } = {}) {
  const getTimeout = opts.getTimeoutMs ?? GET_TIMEOUT_MS;
  const postTimeout = opts.postTimeoutMs ?? POST_TIMEOUT_MS;
  const now = opts.now ?? (() => performance.now());
  async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const init: RequestInit = { method, credentials: "same-origin", headers: { Accept: "application/json" } };
    if (body !== undefined) {
      init.body = JSON.stringify(body);
      init.headers = { ...init.headers, "Content-Type": "application/json" };
    }
    const request = `${method} ${path.split("?")[0]}`;
    const t0 = now();
    const elapsed = () => Math.round(now() - t0);
    // A read that hangs is aborted and named as a timeout (#294); the poller retries. An action whose answer
    // never comes would keep the page locked for good (#289): give up after POST_TIMEOUT_MS; the poller then
    // shows whatever the server has (the action may have been applied).
    const timeoutMs = method === "GET" ? getTimeout : method === "POST" ? postTimeout : 0;
    const ctrl = timeoutMs > 0 && typeof AbortController !== "undefined" ? new AbortController() : null;
    const timer = ctrl ? setTimeout(() => ctrl.abort(), timeoutMs) : null;
    const timeout = () => method === "GET"
      ? new ApiError(0, "timeout", `no answer after ${Math.round(timeoutMs / 1000)} s`, request, elapsed())
      : new ApiError(0, "network", "timeout", request, elapsed());
    try {
      let res: Response;
      try {
        res = await fetchFn(path, ctrl ? { ...init, signal: ctrl.signal } : init);
      } catch (e) {
        if (ctrl?.signal.aborted) throw timeout();
        throw new ApiError(0, "network", e instanceof Error ? e.message : "network error", request, elapsed());
      }
      let data: unknown = null;
      try {
        data = await res.json();
      } catch {
        /* non-JSON body (or the body was cut off): handled below */
        if (ctrl?.signal.aborted) throw timeout();
        if (res.ok && res.status !== 204) throw new ApiError(res.status, "bad_response", `HTTP ${res.status}: no JSON in the answer`, request, elapsed());
      }
      if (!res.ok) {
        const err = (data ?? {}) as { error?: string; message?: string };
        throw new ApiError(res.status, err.error ?? "http_error", err.message ?? `HTTP ${res.status}${res.statusText ? ` ${res.statusText}` : ""}`, request, elapsed());
      }
      return data as T;
    } finally {
      if (timer !== null) clearTimeout(timer);
    }
  }

  return {
    me: () => call<Account>("GET", "/me"),
    map: () => call<MapGeometry>("GET", "/map"),
    // #208: login is the e-mail or the name; the invite code only ever travels in the POST body.
    register: (r: RegisterRequest) => call<Account>("POST", "/register", r),
    login: (login: string, password: string) => call<Account>("POST", "/login", { login, password }),
    // #282 (POC): e-mail only; the server answers with the new password once. Replaced by #283.
    resetPassword: (email: string) => call<{ password: string }>("POST", "/reset-password", { email }),
    logout: () => call<{ ok: boolean }>("POST", "/logout"),
    listGames: () => call<{ games: GameSummary[] }>("GET", "/games"),
    createGame: (seats: SeatRequest[], seed?: number) =>
      call<Game>("POST", "/games", seed === undefined ? { seats } : { seats, seed }),
    getGame: (id: number, log = 40) => call<Game>("GET", `/games/${id}?log=${log}`),
    log: (id: number, from = 0, limit = 500) => call<LogPage>("GET", `/games/${id}/log?from=${from}&limit=${limit}`),
    version: (id: number) => call<Version>("GET", `/games/${id}/version`),
    // #294: a client-side display error goes to the server log (message, stack, browser), so it is not
    // only in the player's console. Best effort; the caller ignores failures.
    clientError: (gameId: number, e: unknown) => call<{ ok: boolean }>("POST", "/client-errors", {
      game_id: gameId,
      message: (e instanceof Error ? `${e.name}: ${e.message}` : String(e)).slice(0, 500),
      stack: (e instanceof Error ? e.stack ?? "" : "").slice(0, 4000),
      agent: typeof navigator === "undefined" ? "" : navigator.userAgent.slice(0, 300),
    }),
    postAction: (id: number, action: Record<string, unknown>, seq: number) =>
      call<Game>("POST", `/games/${id}/actions`, { action, seq }),
  };
}

export type Api = ReturnType<typeof createApi>;
