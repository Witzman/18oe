import { ApiError, type Api } from "./api.ts";
import type { Game } from "./types.ts";

export interface PollerOptions {
  api: Pick<Api, "version" | "getGame">;
  gameId: number;
  onGame: (game: Game) => void;
  onError?: (e: ApiError) => void;
  onUnauthorized?: () => void;
  // A check or load worked (clears the "no connection" band).
  onOk?: () => void;
  // The last check failed; the next attempt follows in `ms` (drives the countdown band). `why` is the real
  // reason (#294): the request, its HTTP status or the network/timeout, the elapsed time, or a display error.
  onRetryIn?: (ms: number, why: PollFailure) => void;
  // Drawing a loaded state threw (a client bug, #294). Reported apart from network errors; the state is
  // loaded again on the next check.
  onRenderError?: (e: unknown) => void;
  isVisible?: () => boolean;
  // Takt (ui-spec 3.7): sichtbarer Reiter schnell, Hintergrund langsam; wieder sichtbar -> sofort (main.ts ruft tick()).
  activeMs?: number;
  hiddenMs?: number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
}

export const POLL_ACTIVE_MS = 2000;
export const POLL_HIDDEN_MS = 10000;

// Why a check failed. kind "render": the state arrived but drawing it threw.
export interface PollFailure {
  kind: "network" | "timeout" | "server" | "render";
  status: number;
  request: string;
  elapsedMs: number | null;
  message: string;
}

export function failureOf(e: unknown): PollFailure {
  if (e instanceof ApiError) {
    const kind = e.code === "timeout" ? "timeout" : e.status === 0 ? "network" : "server";
    return { kind, status: e.status, request: e.request, elapsedMs: e.elapsedMs, message: e.message };
  }
  const message = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
  return { kind: "render", status: 0, request: "", elapsedMs: null, message };
}

export type PollState = "stopped" | "waiting" | "checking" | "loading";

// Polls GET /games/:id/version (cheap) and loads the full state only when seq
// moved. Every 2 s while the tab is visible, every 10 s in the background (so title and favicon stay
// current there); an immediate check when the tab becomes visible again.
export function createPoller(opts: PollerOptions) {
  const visible = opts.isVisible ?? (() => true);
  const nextMs = () => (visible() ? opts.activeMs ?? POLL_ACTIVE_MS : opts.hiddenMs ?? POLL_HIDDEN_MS);
  const setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  const clearTimer = opts.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
  let state: PollState = "stopped";
  // `state` changes across awaits; a function keeps TypeScript from narrowing it.
  const is = (s: PollState) => (state as PollState) === s;
  let lastSeq: number | null = null;
  let handle: unknown = null;
  // >0 while the player's own action is in flight (#162: the poller pauses during sending).
  let paused = 0;
  let failed: PollFailure | null = null;

  function schedule() {
    if (is("stopped")) return;
    state = "waiting";
    const ms = nextMs();
    handle = setTimer(() => void tick(), ms);
    if (failed) opts.onRetryIn?.(ms, failed);
  }

  // One check; used by the timer, on first start and on "tab visible again".
  async function tick(): Promise<void> {
    if (is("stopped") || is("checking") || is("loading")) return;
    if (handle !== null) clearTimer(handle);
    handle = null;
    if (paused > 0) return schedule();
    try {
      state = "checking";
      const v = await opts.api.version(opts.gameId);
      if (is("stopped")) return;
      if (v.seq !== lastSeq) {
        state = "loading";
        const game = await opts.api.getGame(opts.gameId);
        if (is("stopped")) return;
        try {
          opts.onGame(game);
        } catch (e) {
          // #294: a display error used to be reported as "no connection" while lastSeq already pointed at
          // the state, so the next check found nothing new and the band vanished over a half-drawn page.
          // Now it is named as what it is and the state is loaded (and drawn) again on the next check.
          lastSeq = null;
          failed = failureOf(e);
          opts.onRenderError?.(e);
          return schedule();
        }
        lastSeq = game.seq;
      }
      failed = null;
      opts.onOk?.();
    } catch (e) {
      if (is("stopped")) return;
      const err = e instanceof ApiError ? e : new ApiError(0, "network", String(e));
      if (err.status === 401) {
        stop();
        opts.onUnauthorized?.();
        return;
      }
      // Network loss, timeout and server errors (5xx) are retried with the countdown band; the band names
      // the request, the status and the time (#294). Other statuses (404, 4xx) are handled by onError.
      failed = err.status === 0 || err.status >= 500 ? failureOf(err) : null;
      opts.onError?.(err);
    }
    schedule();
  }

  function start() {
    if (!is("stopped")) return;
    state = "waiting";
    void tick();
  }

  function stop() {
    state = "stopped";
    if (handle !== null) clearTimer(handle);
    handle = null;
  }

  // After the player's own action: show the new state right away.
  function adopt(game: Game) {
    lastSeq = game.seq;
    try {
      opts.onGame(game);
    } catch (e) {
      lastSeq = null; // drawn again (and reported) by the next check
      failed = failureOf(e);
      opts.onRenderError?.(e);
      opts.onRetryIn?.(nextMs(), failed);
    }
  }

  // Pause/resume around a sent action. A check that is already running finishes; its result is
  // harmless because the action's answer (full state) goes through adopt() afterwards.
  function pause() { paused++; }
  function resume() { paused = Math.max(0, paused - 1); }

  return { start, stop, pause, resume, get paused() { return paused > 0; }, tick: () => tick(), adopt, get state() { return state; }, get lastSeq() { return lastSeq; } };
}
