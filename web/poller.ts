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
  // The last check failed; the next attempt follows in `ms` (drives the countdown band).
  onRetryIn?: (ms: number) => void;
  isVisible?: () => boolean;
  intervalMs?: number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
}

export type PollState = "stopped" | "waiting" | "checking" | "loading";

// Polls GET /games/:id/version (cheap) and loads the full state only when seq
// moved. Skips while the tab is hidden; resumes with an immediate check.
export function createPoller(opts: PollerOptions) {
  const interval = opts.intervalMs ?? 5000;
  const visible = opts.isVisible ?? (() => true);
  const setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  const clearTimer = opts.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
  let state: PollState = "stopped";
  // `state` changes across awaits; a function keeps TypeScript from narrowing it.
  const is = (s: PollState) => (state as PollState) === s;
  let lastSeq: number | null = null;
  let handle: unknown = null;
  // >0 while the player's own action is in flight (#162: the poller pauses during sending).
  let paused = 0;
  let failed = false;

  function schedule() {
    if (is("stopped")) return;
    state = "waiting";
    handle = setTimer(() => void tick(), interval);
    if (failed) opts.onRetryIn?.(interval);
  }

  // One check; used by the timer, on first start and on "tab visible again".
  async function tick(force = false): Promise<void> {
    if (is("stopped") || is("checking") || is("loading")) return;
    if (handle !== null) clearTimer(handle);
    handle = null;
    if (paused > 0 || (!visible() && !force)) return schedule();
    try {
      state = "checking";
      const v = await opts.api.version(opts.gameId);
      if (is("stopped")) return;
      if (v.seq !== lastSeq) {
        state = "loading";
        const game = await opts.api.getGame(opts.gameId);
        if (is("stopped")) return;
        lastSeq = game.seq;
        opts.onGame(game);
      }
      failed = false;
      opts.onOk?.();
    } catch (e) {
      if (is("stopped")) return;
      const err = e instanceof ApiError ? e : new ApiError(0, "network", String(e));
      if (err.status === 401) {
        stop();
        opts.onUnauthorized?.();
        return;
      }
      failed = err.status === 0;
      opts.onError?.(err);
    }
    schedule();
  }

  function start() {
    if (!is("stopped")) return;
    state = "waiting";
    void tick(true);
  }

  function stop() {
    state = "stopped";
    if (handle !== null) clearTimer(handle);
    handle = null;
  }

  // After the player's own action: show the new state right away.
  function adopt(game: Game) {
    lastSeq = game.seq;
    opts.onGame(game);
  }

  // Pause/resume around a sent action. A check that is already running finishes; its result is
  // harmless because the action's answer (full state) goes through adopt() afterwards.
  function pause() { paused++; }
  function resume() { paused = Math.max(0, paused - 1); }

  return { start, stop, pause, resume, get paused() { return paused > 0; }, tick: () => tick(), adopt, get state() { return state; }, get lastSeq() { return lastSeq; } };
}
